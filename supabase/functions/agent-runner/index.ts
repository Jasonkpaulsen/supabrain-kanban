// agent-runner — SB-241
// The execution loop that turns automation flags into real agent work.
//
// Phases:
//   assign   (deterministic, safe)  — match unassigned/ready tickets to agents via auto_assign_rules
//   sweep    (deterministic, safe)  — idle-agent / WIP-overload / assignment+design drift detection
//   dispatch (LLM, opt-in per call) — invoke the assigned agent's model to produce a plan comment
//
// Auth: custom x-token header (mirrors lce-cleanup). Invoked by pg_cron via net.http_post.
// Governance: dispatch runs ONLY when the caller explicitly requests phase "dispatch" (cron body)
// AND an ANTHROPIC_API_KEY secret is present; it never auto-acts on tickets with authority_level >= 2
// (recommend/approval/executive — those need Jason). The assign/sweep crons never include "dispatch".
// Dispatch is scopeable via body.dispatchProjects (list of project ids) and guarded once-per-ticket
// (a work item with a completed run is never re-dispatched). Candidates ordered by sort_order.

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
  // Dispatch is opt-in per invocation: the caller must explicitly include phase "dispatch"
  // (only a dedicated dispatch cron does) AND an ANTHROPIC_API_KEY must be present.
  const dispatchEnabled = phases.includes("dispatch");

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

  // ============ PHASE C: DISPATCH (LLM — opt-in via phase "dispatch" + ANTHROPIC_API_KEY) ============
  if (dispatchEnabled) {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      (out as any).dispatch_note = "phase 'dispatch' requested but ANTHROPIC_API_KEY is not set — dispatch skipped";
    } else {
      const maxDispatch = typeof body.maxDispatch === "number" ? (body.maxDispatch as number) : 3;
      // Optional project scoping (e.g. CIP-only dispatch) — intersect with automated projects.
      const reqScope = Array.isArray(body.dispatchProjects) ? (body.dispatchProjects as string[]) : null;
      const scopeIds = reqScope ? projIds.filter((id) => reqScope.includes(id)) : projIds;
      // forceItems (ticket_codes) bypass the once-per-ticket guard — used to re-kick a ticket after a blocker clears.
      const forceCodes = Array.isArray(body.forceItems) ? (body.forceItems as string[]) : [];
      // Once-per-ticket guard: never re-dispatch a ticket that already has ANY run
      // (running/completed/failed). Keying on "any run" is robust to telemetry hiccups.
      const { data: priorRuns } = await sb.from("agent_runs").select("work_item_id").not("work_item_id", "is", null);
      const alreadyDispatched = new Set((priorRuns ?? []).map((r: any) => r.work_item_id));
      const { data: readyRaw } = await sb.from("work_items")
        .select("id,project_id,ticket_code,title,description,type,status,assigned_agent_id,authority_level,sort_order")
        .in("project_id", scopeIds.length ? scopeIds : ["00000000-0000-0000-0000-000000000000"])
        .eq("status", "todo")
        .not("assigned_agent_id", "is", null)
        .order("sort_order", { ascending: true })
        .limit(200); // fetch a wide window; the guard + authority filters below select the real candidates
      // forced re-kicks: fetch by ticket_code in scope, any status, exempt from the once-per-ticket guard
      let forced: any[] = [];
      if (forceCodes.length) {
        const { data: forcedRaw } = await sb.from("work_items")
          .select("id,project_id,ticket_code,title,description,type,status,assigned_agent_id,authority_level,sort_order")
          .in("ticket_code", forceCodes)
          .in("project_id", scopeIds.length ? scopeIds : ["00000000-0000-0000-0000-000000000000"]);
        forced = (forcedRaw ?? []).filter((it: any) => (it.authority_level ?? 0) < 2 && it.assigned_agent_id);
      }
      const forcedIds = new Set(forced.map((f: any) => f.id));
      const fresh = (readyRaw ?? []).filter((it: any) => !alreadyDispatched.has(it.id) && !forcedIds.has(it.id));
      // authority_level >= 2 needs Jason — report it but do NOT let it consume a dispatch slot
      for (const it of fresh.filter((it: any) => (it.authority_level ?? 0) >= 2)) {
        skipped.push({ id: it.id, title: it.title, reason: `authority L${it.authority_level} — requires Jason, not auto-dispatched` });
      }
      const ready = [...forced, ...fresh.filter((it: any) => (it.authority_level ?? 0) < 2)].slice(0, maxDispatch);

      for (const it of (ready ?? []) as any[]) {
        const ag = agents.find((a) => a.id === it.assigned_agent_id);
        if (!ag) continue;
        if (dryRun) { dispatched.push({ id: it.id, agent: ag.name, mode: "dry" }); continue; }

        const startedAt = Date.now();
        try {
          await sb.from("agent_runs").insert({
            user_id: ag.user_id, agent_id: ag.id, work_item_id: it.id, project_id: it.project_id,
            started_at: new Date(startedAt).toISOString(), status: "running", trigger_type: "scheduled",
          });

          const sys = [
            ag.system_prompt ?? "",
            ag.goals?.length ? `\n\nGoals:\n- ${ag.goals.join("\n- ")}` : "",
            ag.constraints?.length ? `\n\nConstraints:\n- ${ag.constraints.join("\n- ")}` : "",
            "\n\nYou are running unattended via the agent runner. Produce a concise, actionable plan for the ticket below: the approach, the concrete steps, acceptance criteria you will satisfy, and any blockers/escalations. Do NOT claim work is done. If this needs a decision above your authority, say so and name who to escalate to.",
          ].join("");
          const userMsg = `Ticket ${it.ticket_code}: ${it.title}\nType: ${it.type}\n\n${it.description ?? "(no description)"}`;

          const resp = await fetch("https://api.anthropic.com/v1/messages", {
            method: "POST",
            headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
            body: JSON.stringify({
              model: ag.model || "claude-sonnet-5",
              max_tokens: 4096,
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
          // NB: duration_ms and tokens_total are GENERATED columns — never write them.
          await sb.from("agent_runs").update({
            finished_at: new Date().toISOString(), status: "completed",
            tokens_input: usage.input_tokens ?? null, tokens_output: usage.output_tokens ?? null,
            api_calls: 1, result_summary: `Posted plan for "${it.title}"`,
          }).eq("work_item_id", it.id).eq("status", "running");
          await sb.from("agents").update({
            last_run_at: new Date().toISOString(), run_count: (ag.run_count ?? 0) + 1,
          }).eq("id", ag.id);
          dispatched.push({ id: it.id, agent: ag.name, mode: "live", chars: text.length });
        } catch (e) {
          await sb.from("agent_runs").update({
            finished_at: new Date().toISOString(),
            status: "failed", error_message: String(e),
          }).eq("work_item_id", it.id).eq("status", "running");
          dispatched.push({ id: it.id, agent: ag.name, mode: "error", error: String(e) });
        }
      }
    }
  }

  return json(out);
});
