// agent-runner — SB-241
// The execution loop that turns automation flags into real agent work.
//
// Phases:
//   assign   (deterministic, safe)  — match unassigned/ready tickets to agents via auto_assign_rules
//   sweep    (deterministic, safe)  — idle-agent / WIP-overload / assignment+design drift detection
//   dispatch (LLM, OFF by default)  — invoke the assigned agent's model to produce a plan comment
//
// Auth: custom x-token header (mirrors lce-cleanup). Invoked by pg_cron via net.http_post.
// Governance: dispatch is gated behind ENABLE_DISPATCH=true AND ANTHROPIC_API_KEY, never auto-acts
// on tickets with authority_level >= 2 (recommend/approval/executive — those need Jason).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const TOKEN = "agent-run-9Fp3xQ2mWz";

// label -> the engineer role that should own that work (used for drift detection)
const ROLE_BY_LABEL: Record<string, string> = {
  "Back-end": "CIP Back End Developer",
  "Front-end": "CIP Front End Developer",
  "Middleware/Integration": "CIP Middleware/Integration Engineer",
};

type Rule = { match?: { label?: string; type?: string }; scope_projects?: string[] };
type Agent = {
  id: string;
  name: string;
  user_id: string;
  automation_enabled: boolean;
  max_concurrent_tasks: number | null;
  auto_assign_rules: Rule[] | null;
  last_run_at: string | null;
  run_count: number | null;
  system_prompt: string | null;
  goals: string[] | null;
  constraints: string[] | null;
  model: string | null;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.headers.get("x-token") !== TOKEN) return new Response("forbidden", { status: 403 });

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch (_) { /* empty body ok */ }

  const dryRun = body.dryRun === true;
  const phases: string[] = Array.isArray(body.phases) && body.phases.length
    ? (body.phases as string[])
    : ["assign", "sweep"];
  const dispatchEnabled = Deno.env.get("ENABLE_DISPATCH") === "true" && phases.includes("dispatch");

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const out: Record<string, unknown> = {
    ok: true, dryRun, phases, at: new Date().toISOString(),
    assigned: [] as unknown[], skipped: [] as unknown[], sweep: [] as unknown[], dispatched: [] as unknown[],
  };
  const assigned = out.assigned as unknown[];
  const skipped = out.skipped as unknown[];
  const sweep = out.sweep as unknown[];
  const dispatched = out.dispatched as unknown[];

  // ---- Active automated projects (meta.dev_automation = 'on') ----
  const { data: projs } = await sb.from("projects").select("id,name,user_id,meta,archived").eq("archived", false);
  const activeProjects = (projs ?? []).filter((p: any) => p?.meta?.dev_automation === "on");
  const projIds = activeProjects.map((p: any) => p.id);
  const userOf = (pid: string) => activeProjects.find((p: any) => p.id === pid)?.user_id ?? null;
  if (!projIds.length) { (out as any).note = "no projects with dev_automation=on"; return json(out); }

  // ---- Automation-enabled agents ----
  const { data: agentsRaw } = await sb.from("agents")
    .select("id,name,user_id,automation_enabled,max_concurrent_tasks,auto_assign_rules,last_run_at,run_count,system_prompt,goals,constraints,model")
    .eq("automation_enabled", true);
  const agents = (agentsRaw ?? []) as Agent[];

  // labels for a set of work_item ids -> { itemId: [labelName,...] }
  async function labelsFor(ids: string[]): Promise<Record<string, string[]>> {
    const map: Record<string, string[]> = {};
    if (!ids.length) return map;
    const { data } = await sb.from("work_item_labels").select("work_item_id,labels(name)").in("work_item_id", ids);
    for (const r of (data ?? []) as any[]) {
      const nm = r.labels?.name;
      if (nm) (map[r.work_item_id] ||= []).push(nm);
    }
    return map;
  }

  // ============ PHASE A: AUTO-ASSIGN ============
  if (phases.includes("assign")) {
    const { data: items } = await sb.from("work_items")
      .select("id,project_id,title,type,status,assigned_agent_id,authority_level")
      .in("project_id", projIds)
      .is("assigned_agent_id", null)
      .in("status", ["backlog", "todo"]);
    const labelMap = await labelsFor((items ?? []).map((i: any) => i.id));

    for (const it of (items ?? []) as any[]) {
      const lbls = labelMap[it.id] ?? [];
      // pick the most specific matching (agent, rule): label match (2) beats type match (1)
      let best: { agent: Agent; spec: number } | null = null;
      for (const ag of agents) {
        for (const rule of ag.auto_assign_rules ?? []) {
          const scope = rule.scope_projects ?? [];
          if (scope.length && !scope.includes(it.project_id)) continue;
          const m = rule.match ?? {};
          let spec = 0;
          if (m.label !== undefined) { if (!lbls.includes(m.label)) continue; spec += 2; }
          if (m.type !== undefined) { if (it.type !== m.type) continue; spec += 1; }
          if (spec === 0) continue; // ignore empty/catch-all matches
          if (!best || spec > best.spec) best = { agent: ag, spec };
        }
      }
      if (!best) { skipped.push({ id: it.id, title: it.title, reason: "no rule match", labels: lbls, type: it.type }); continue; }

      assigned.push({ id: it.id, title: it.title, agent: best.agent.name, via: best.spec >= 2 ? "label" : "type" });
      if (!dryRun) {
        await sb.from("work_items").update({
          assigned_agent_id: best.agent.id, assignee: best.agent.name, updated_at: new Date().toISOString(),
        }).eq("id", it.id);
        await sb.from("activity_log").insert({
          project_id: it.project_id, user_id: userOf(it.project_id), agent_name: "Agent Runner", action: "auto_assign",
          target_table: "work_items", target_id: it.id,
          summary: `Auto-assigned "${it.title}" to ${best.agent.name}`,
          meta: { labels: lbls, type: it.type, specificity: best.spec },
        });
      }
    }
  }

  // ============ PHASE B: IDLE / DRIFT SWEEP ============
  if (phases.includes("sweep")) {
    const { data: open } = await sb.from("work_items")
      .select("id,project_id,title,type,status,assigned_agent_id,assignee")
      .in("project_id", projIds)
      .in("status", ["backlog", "todo", "in_progress"])
      .not("assigned_agent_id", "is", null);
    const openItems = (open ?? []) as any[];

    const counts: Record<string, number> = {};
    for (const it of openItems) counts[it.assigned_agent_id] = (counts[it.assigned_agent_id] ?? 0) + 1;

    const weekAgo = Date.now() - 7 * 86400000;
    for (const ag of agents) {
      const openN = counts[ag.id] ?? 0;
      const idle = !ag.last_run_at || new Date(ag.last_run_at).getTime() < weekAgo;
      if (openN > 0 && idle) sweep.push({ type: "idle_agent", agent: ag.name, open_items: openN, last_run_at: ag.last_run_at });
      const cap = ag.max_concurrent_tasks ?? 5;
      if (openN > cap * 3) sweep.push({ type: "wip_overload", agent: ag.name, open_items: openN, cap });
    }

    const lmap = await labelsFor(openItems.map((i) => i.id));
    for (const it of openItems) {
      const lbls = lmap[it.id] ?? [];
      for (const [lab, expected] of Object.entries(ROLE_BY_LABEL)) {
        if (lbls.includes(lab) && it.assignee && it.assignee !== expected) {
          sweep.push({ type: "assignment_drift", id: it.id, title: it.title, label: lab, expected, actual: it.assignee });
        }
      }
      const hasDevLabel = lbls.some((l) => l in ROLE_BY_LABEL);
      if (it.type === "spike" && it.assignee && !/Architect/.test(it.assignee) && !hasDevLabel) {
        sweep.push({ type: "design_drift", id: it.id, title: it.title, actual: it.assignee, note: "spike not owned by Architect" });
      }
    }

    if (!dryRun && sweep.length) {
      await sb.from("activity_log").insert({
        project_id: projIds[0], user_id: userOf(projIds[0]), agent_name: "SupaBrain Process Engineer", action: "pe_sweep",
        target_table: "agents", summary: `Flow/governance sweep: ${sweep.length} finding(s)`, meta: { findings: sweep },
      });
    }
  }

  // ============ PHASE C: DISPATCH (LLM — OFF by default) ============
  if (dispatchEnabled) {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      (out as any).dispatch_note = "ENABLE_DISPATCH=true but ANTHROPIC_API_KEY is not set — dispatch skipped";
    } else {
      const maxDispatch = typeof body.maxDispatch === "number" ? (body.maxDispatch as number) : 3;
      const { data: ready } = await sb.from("work_items")
        .select("id,project_id,title,description,type,status,assigned_agent_id,authority_level")
        .in("project_id", projIds)
        .eq("status", "todo")
        .not("assigned_agent_id", "is", null)
        .limit(maxDispatch);

      for (const it of (ready ?? []) as any[]) {
        const ag = agents.find((a) => a.id === it.assigned_agent_id);
        if (!ag) continue;
        if ((it.authority_level ?? 0) >= 2) {
          skipped.push({ id: it.id, title: it.title, reason: `authority L${it.authority_level} — requires Jason, not auto-dispatched` });
          continue;
        }
        if (dryRun) { dispatched.push({ id: it.id, agent: ag.name, mode: "dry" }); continue; }

        const startedAt = Date.now();
        let runId: string | null = null;
        try {
          const { data: run } = await sb.from("agent_runs").insert({
            user_id: ag.user_id, agent_id: ag.id, work_item_id: it.id, project_id: it.project_id,
            started_at: new Date(startedAt).toISOString(), status: "running", trigger_type: "scheduled",
          }).select("id").single();
          runId = (run as any)?.id ?? null;

          const sys = [
            ag.system_prompt ?? "",
            ag.goals?.length ? `\n\nGoals:\n- ${ag.goals.join("\n- ")}` : "",
            ag.constraints?.length ? `\n\nConstraints:\n- ${ag.constraints.join("\n- ")}` : "",
            "\n\nYou are running unattended via the agent runner. Produce a concise, actionable plan for the ticket below: the approach, the concrete steps, acceptance criteria you will satisfy, and any blockers/escalations. Do NOT claim work is done. If this needs a decision above your authority, say so and name who to escalate to.",
          ].join("");
          const userMsg = `Ticket: ${it.title}\nType: ${it.type}\n\n${it.description ?? "(no description)"}`;

          const resp = await fetch("https://api.anthropic.com/v1/messages", {
            method: "POST",
            headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
            body: JSON.stringify({
              model: ag.model || "claude-sonnet-4-6",
              max_tokens: 1024,
              system: sys,
              messages: [{ role: "user", content: userMsg }],
            }),
          });
          const data = await resp.json();
          const text = (data?.content ?? []).map((c: any) => c?.text ?? "").join("").trim() || "(no output)";
          const usage = data?.usage ?? {};

          await sb.from("work_item_comments").insert({
            work_item_id: it.id, user_id: ag.user_id, body: `**${ag.name}** (auto-run plan):\n\n${text}`,
          });
          if (runId) {
            await sb.from("agent_runs").update({
              finished_at: new Date().toISOString(), duration_ms: Date.now() - startedAt, status: "completed",
              tokens_input: usage.input_tokens ?? null, tokens_output: usage.output_tokens ?? null,
              tokens_total: (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0), api_calls: 1,
              result_summary: `Posted plan for "${it.title}"`,
            }).eq("id", runId);
          }
          await sb.from("agents").update({
            last_run_at: new Date().toISOString(), run_count: (ag.run_count ?? 0) + 1,
          }).eq("id", ag.id);
          dispatched.push({ id: it.id, agent: ag.name, mode: "live", chars: text.length });
        } catch (e) {
          if (runId) {
            await sb.from("agent_runs").update({
              finished_at: new Date().toISOString(), duration_ms: Date.now() - startedAt,
              status: "failed", error_message: String(e),
            }).eq("id", runId);
          }
          dispatched.push({ id: it.id, agent: ag.name, mode: "error", error: String(e) });
        }
      }
    }
  }

  return json(out);
});
