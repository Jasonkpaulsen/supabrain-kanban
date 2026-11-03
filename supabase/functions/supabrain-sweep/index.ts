// supabrain-sweep — SB-482
//
// One token-gated HTTP endpoint for the recurring board sweeps, so a scheduled
// task can run them with a single web_fetch instead of a series of execute_sql
// calls that stall on a tool-approval prompt with nobody at the keyboard.
//
// ---------------------------------------------------------------------------
// THIS ENDPOINT DOES NOT ACCEPT SQL. That is the whole security design.
// ---------------------------------------------------------------------------
// SB-482 as written asks for "all sweep SQL operations behind a single HTTP
// endpoint … parameterized queries for all three sweep types". Read literally
// that is a SQL-over-HTTP gateway holding the service-role key behind one
// bearer token. This project has already published three live tokens
// (SB-408, SB-440, SB-447), and lce-cleanup still carries its token as a
// literal in both its source and cron.job.command. A leak of THIS token, if it
// took arbitrary SQL, would be equivalent to handing over the database.
//
// So the caller names an OPERATION and passes typed parameters; the SQL lives
// here, fixed, and is never assembled from caller input. Adding a capability
// means editing this allow-list and redeploying — a reviewable change — not
// sending a different string. An unknown operation is a 400 that lists the
// valid names; there is no fallthrough that executes anything.
//
// Auth: x-token header, checked against Vault via
// public.supabrain_sweep_token_matches(). Following SB-440, this file holds no
// literal token and the database never returns the secret — the RPC answers
// only true/false and is EXECUTE-granted to service_role alone. Do not
// reintroduce a literal here; that is what lce-cleanup does and it is a defect.
//
// verify_jwt is deliberately OFF, as it is on agent-runner. Turning it on would
// require every caller to also present the project anon key, which is public
// anyway (SB-182) and so adds no real control — while coupling this endpoint to
// a key SB-182 exists to rotate. The Vault token is the control.
//
// Effects: every operation declares whether it mutates. `dryRun: true` runs the
// read-only ones and reports the mutating ones as skipped, so a caller can see
// exactly what a sweep would touch before letting it touch anything.
//
// Parameters and truncation (SB-495): see params.ts. Each operation declares
// what its parameters mean; a flat name two operations disagree about is
// refused rather than applied to both. Every list result carries `truncated`
// and `total`, and the response names any result that was cut short.
//
// External waits (SB-593, ADR-FLOW-005 D3 / D3a): stale_wip, blocked_items and
// review_queue_aging read v_open_work_wait_state and skip any item the database
// classifier says is waiting on an outside party (OPEN_WORK_VIEW in ops.ts); the
// edge does not re-derive the rule. external_waits lists those items from
// v_external_wait_status, split into on-track, expired and no-clock, with severity
// and any data-quality issue. Expired waits surface there, once, rather than as
// stale work. wip_queue (SB-598)
// and decision_digest (SB-554) are read-only views of objects the database
// owns.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { PARAM_SPECS, resolveParams, truncated } from "./params.ts";
import {
  EXTERNAL_WAIT_FIELDS, type ExternalWaitRow, groupExternalWaits, groupWipQueue, OPEN_WORK_VIEW,
  WIP_QUEUE_FIELDS, type WipQueueRow, deployDriftReport, type DeployDriftRow,
} from "./ops.ts";

const MAX_ROWS = 500;          // hard cap on any single read
const WORK_ITEM_SCAN = 5000;   // cap on the per-agent work-item fetch
const OPEN = ["backlog", "todo", "in_progress"];

type Ctx = { sb: SupabaseClient; p: Record<string, number> };
type Op = {
  mutates: boolean;
  summary: string;
  run: (c: Ctx) => Promise<unknown>;
};

/**
 * A capped read, with the database's exact count of matching rows alongside.
 * Build the query with select(cols, { count: "exact" }) so `count` is set.
 */
function listed<T>(
  r: { data: T[] | null; error: { message: string } | null; count: number | null },
  limit: number,
): { rows: T[]; total: number | null; truncated: boolean } {
  const rows = unwrap(r) as T[];
  const total = r.count ?? null;
  return { rows, total, truncated: truncated(rows.length, total, limit) };
}

function isoDaysAgo(days: number): string {
  return new Date(Date.now() - days * 86_400_000).toISOString();
}
function isoHoursAgo(hours: number): string {
  return new Date(Date.now() - hours * 3_600_000).toISOString();
}

/** Unwrap a PostgREST result, turning an error into a thrown Error. */
function unwrap<T>(r: { data: T | null; error: { message: string } | null }): T {
  if (r.error) throw new Error(r.error.message);
  return (r.data ?? []) as T;
}

/**
 * Agents a management sweep should actually judge.
 *
 * Found by running this endpoint against production before shipping it: the
 * first version filtered on automation_enabled alone and reported six agents
 * with no reporting line. Four were `status = 'archived'` and the other two
 * were seeded QA fixtures (meta.qa_fixture). The true count is zero, so the
 * management sweep would have raised six false gaps every day -- which is
 * exactly SB-376, where handoff detection measured the wrong field and
 * produced 29 false positives. Filter once, here, so all three management
 * operations agree on who counts.
 */
function liveAgents<T extends { status?: unknown; meta?: unknown }>(rows: T[]): T[] {
  return rows.filter((a) =>
    a.status === "active" &&
    !((a.meta as Record<string, unknown> | null)?.qa_fixture === true));
}

// ===========================================================================
// The allow-list. Everything this endpoint can do is in this object.
// ===========================================================================
const OPERATIONS: Record<string, Op> = {
  // --- smoke test -----------------------------------------------------------
  ping: {
    mutates: false,
    summary: "Auth and connectivity check; touches one row.",
    run: async ({ sb }) => {
      const rows = unwrap(await sb.from("projects").select("id").limit(1));
      return { ok: true, reachable: rows.length > 0 };
    },
  },

  // --- process-engineer-daily ----------------------------------------------
  // These four already exist as SECURITY DEFINER functions granted to
  // service_role only. The endpoint calls them; it does not reimplement them.
  qa_shiftleft_sweep: {
    mutates: true,
    summary: "public.qa_shiftleft_sweep() — QA coverage gaps.",
    run: async ({ sb }) => unwrap(await sb.rpc("qa_shiftleft_sweep")),
  },
  review_sla_sweep: {
    mutates: true,
    summary: "public.review_sla_sweep() — review-queue SLA breaches.",
    run: async ({ sb }) => unwrap(await sb.rpc("review_sla_sweep")),
  },
  cron_health_check: {
    mutates: true,
    summary: "public.cron_health_check() — scheduled-job health.",
    run: async ({ sb }) => unwrap(await sb.rpc("cron_health_check")),
  },
  backlog_grooming_report: {
    // SB-495: was declared mutates:false, but the function inserts an
    // activity_log row on every call, so dryRun ran it and wrote. It changes
    // no work item; it does write.
    mutates: true,
    summary: "public.backlog_grooming_report(p_stale_days) — backlog age report; writes one activity_log row.",
    run: async ({ sb, p }) =>
      unwrap(await sb.rpc("backlog_grooming_report", { p_stale_days: p.staleDays })),
  },

  // --- management-agent-sweep ----------------------------------------------
  agents_missing_chain: {
    mutates: false,
    summary: "SB-240: automation-enabled agents with no reporting line, which breaks coverage checks.",
    run: async ({ sb }) => {
      const r = listed(await sb.from("agents")
        .select("id,name,status,meta,automation_enabled,reports_to_agent_id,reports_to_human,escalation_ceiling",
                { count: "exact" })
        .eq("automation_enabled", true)
        .is("reports_to_agent_id", null)
        .is("reports_to_human", null)
        .limit(MAX_ROWS), MAX_ROWS);
      const raw = r.rows as Array<Record<string, unknown>>;
      const rows = liveAgents(raw).map(({ meta: _meta, ...rest }) => rest);
      return { count: rows.length, excluded_archived_or_fixture: raw.length - rows.length,
               truncated: r.truncated, total: r.total, agents: rows };
    },
  },
  agent_load: {
    mutates: false,
    summary: "Open items per agent against max_concurrent_tasks; flags over-capacity.",
    run: async ({ sb }) => {
      const a = listed(await sb.from("agents")
        .select("id,name,status,meta,max_concurrent_tasks,automation_enabled,last_run_at", { count: "exact" })
        .limit(MAX_ROWS), MAX_ROWS);
      const agents = liveAgents(a.rows as Array<Record<string, unknown>>);
      const w = listed(await sb.from("work_items")
        .select("assigned_agent_id", { count: "exact" })
        .in("status", OPEN)
        .not("assigned_agent_id", "is", null)
        .limit(WORK_ITEM_SCAN), WORK_ITEM_SCAN);
      const counts: Record<string, number> = {};
      for (const it of w.rows as Array<{ assigned_agent_id: string }>) {
        counts[it.assigned_agent_id] = (counts[it.assigned_agent_id] ?? 0) + 1;
      }
      const rows = agents
        .map((a) => {
          const open = counts[a.id as string] ?? 0;
          const cap = (a.max_concurrent_tasks as number | null) ?? 5;
          return { agent: a.name, open, cap, over_capacity: open > cap, last_run_at: a.last_run_at };
        })
        .filter((r) => r.open > 0)
        .sort((x, y) => y.open - x.open);
      // A short work-item fetch undercounts every agent, not just the tail.
      return { count: rows.length, over_capacity: rows.filter((r) => r.over_capacity).length,
               truncated: a.truncated || w.truncated,
               total_agents: a.total, open_items_scanned: w.rows.length, open_items_total: w.total,
               agents: rows };
    },
  },
  agents_idle_with_queue: {
    mutates: false,
    summary: "Agents holding open work that have not run in idleDays.",
    run: async ({ sb, p }) => {
      const cutoff = isoDaysAgo(p.idleDays);
      const a = listed(await sb.from("agents")
        .select("id,name,status,meta,last_run_at", { count: "exact" })
        .limit(MAX_ROWS), MAX_ROWS);
      const agents = liveAgents(a.rows as Array<Record<string, unknown>>);
      const w = listed(await sb.from("work_items")
        .select("assigned_agent_id", { count: "exact" }).in("status", OPEN)
        .not("assigned_agent_id", "is", null).limit(WORK_ITEM_SCAN), WORK_ITEM_SCAN);
      const counts: Record<string, number> = {};
      for (const it of w.rows as Array<{ assigned_agent_id: string }>) {
        counts[it.assigned_agent_id] = (counts[it.assigned_agent_id] ?? 0) + 1;
      }
      const rows = agents
        .filter((a) => (counts[a.id as string] ?? 0) > 0)
        .filter((a) => !a.last_run_at || (a.last_run_at as string) < cutoff)
        .map((a) => ({ agent: a.name, open: counts[a.id as string], last_run_at: a.last_run_at }));
      return { cutoff, count: rows.length, truncated: a.truncated || w.truncated,
               total_agents: a.total, open_items_scanned: w.rows.length, open_items_total: w.total,
               agents: rows };
    },
  },

  // --- pm-triage-dispatch ---------------------------------------------------
  untriaged_items: {
    mutates: false,
    summary: "Non-archived backlog items with neither an assignee nor an assigned agent.",
    run: async ({ sb }) => {
      const r = listed(await sb.from("work_items")
        .select("ticket_code,title,type,priority,project_id,created_at", { count: "exact" })
        .eq("archived", false)
        .eq("status", "backlog")
        .is("assigned_agent_id", null)
        .is("assignee", null)
        .order("created_at", { ascending: true })
        .limit(MAX_ROWS), MAX_ROWS);
      return { count: r.rows.length, total: r.total, truncated: r.truncated, items: r.rows };
    },
  },
  review_queue_aging: {
    mutates: false,
    summary: "Items in review longer than ageHours, skipping items waiting on an outside party (see external_waits).",
    run: async ({ sb, p }) => {
      const hours = p.ageHours;
      const r = listed(await sb.from(OPEN_WORK_VIEW)
        .select("ticket_code,title,assignee,priority,review_entered_at,project_id", { count: "exact" })
        .eq("status", "review")
        .is("wait_state", null)
        .lt("review_entered_at", isoHoursAgo(hours))
        .order("review_entered_at", { ascending: true })
        .limit(MAX_ROWS), MAX_ROWS);
      return { age_hours: hours, count: r.rows.length, total: r.total, truncated: r.truncated, items: r.rows };
    },
  },
  stale_wip: {
    mutates: false,
    summary: "in_progress items untouched for staleDays, skipping items waiting on an outside party (see external_waits).",
    run: async ({ sb, p }) => {
      const days = p.staleDays;
      const r = listed(await sb.from(OPEN_WORK_VIEW)
        .select("ticket_code,title,assignee,priority,updated_at,project_id", { count: "exact" })
        .eq("status", "in_progress")
        .is("wait_state", null)
        .lt("updated_at", isoDaysAgo(days))
        .order("updated_at", { ascending: true })
        .limit(MAX_ROWS), MAX_ROWS);
      return { stale_days: days, count: r.rows.length, total: r.total, truncated: r.truncated, items: r.rows };
    },
  },
  blocked_items: {
    mutates: false,
    summary: "blocked / on_hold items untouched for staleDays, skipping items waiting on an outside party (see external_waits).",
    run: async ({ sb, p }) => {
      const days = p.staleDays;
      const r = listed(await sb.from(OPEN_WORK_VIEW)
        .select("ticket_code,title,status,assignee,priority,updated_at,project_id", { count: "exact" })
        .in("status", ["blocked", "on_hold"])
        .is("wait_state", null)
        .lt("updated_at", isoDaysAgo(days))
        .order("updated_at", { ascending: true })
        .limit(MAX_ROWS), MAX_ROWS);
      return { stale_days: days, count: r.rows.length, total: r.total, truncated: r.truncated, items: r.rows };
    },
  },
  awaiting_human: {
    mutates: false,
    summary: "Items parked on a person: status awaiting_jason, or L3+ not yet approved.",
    run: async ({ sb }) => {
      const parked = listed(await sb.from("work_items")
        .select("ticket_code,title,status,priority,updated_at,project_id", { count: "exact" })
        .eq("archived", false).eq("status", "awaiting_jason")
        .order("updated_at", { ascending: true }).limit(MAX_ROWS), MAX_ROWS);
      const unapproved = listed(await sb.from("work_items")
        .select("ticket_code,title,status,authority_level,approval_status,project_id", { count: "exact" })
        .eq("archived", false).gte("authority_level", 3)
        .neq("approval_status", "approved")
        .in("status", OPEN).limit(MAX_ROWS), MAX_ROWS);
      return { awaiting_jason: parked.rows, unapproved_l3_plus: unapproved.rows,
               count: parked.rows.length + unapproved.rows.length,
               total: (parked.total ?? parked.rows.length) + (unapproved.total ?? unapproved.rows.length),
               truncated: parked.truncated || unapproved.truncated };
    },
  },

  // --- ADR-FLOW-005 (SB-593, SB-598, SB-554): read-only views the database owns
  external_waits: {
    mutates: false,
    summary: "SB-593: open items waiting on an outside party (v_external_wait_status), as on_track / expired / no_clock. " +
      "Expired = their window lapsed, follow up; no_clock = data-quality gap. Each row carries severity and " +
      "data_quality_issue (SB-603); counts.data_quality counts the rows with an issue, expired ones included.",
    run: async ({ sb }) => {
      const r = listed(await sb.from("v_external_wait_status")
        .select([...EXTERNAL_WAIT_FIELDS, "wait_state"].join(","), { count: "exact" })
        .order("days_to_clock", { ascending: true, nullsFirst: false })
        .limit(MAX_ROWS), MAX_ROWS);
      const g = groupExternalWaits(r.rows as unknown as ExternalWaitRow[]);
      return { ...g, count: r.rows.length, total: r.total, truncated: r.truncated };
    },
  },
  wip_queue: {
    mutates: false,
    summary: "SB-598: tickets parked by enforce_wip_limit (v_wip_queue), grouped by assignee; ready = assignee has a free slot.",
    run: async ({ sb }) => {
      const r = listed(await sb.from("v_wip_queue")
        .select(WIP_QUEUE_FIELDS.join(","), { count: "exact" })
        .order("assignee", { ascending: true })
        .order("priority", { ascending: true })
        .order("blocked_at", { ascending: true })
        .limit(MAX_ROWS), MAX_ROWS);
      const g = groupWipQueue(r.rows as unknown as WipQueueRow[]);
      return { ...g, count: r.rows.length, total: r.total, truncated: r.truncated };
    },
  },
  decision_digest: {
    mutates: false,
    summary: "SB-554: public.jason_decision_digest() — each open item waiting on Jason once, with aging and folded no-op escalations.",
    run: async ({ sb }) => unwrap(await sb.rpc("jason_decision_digest")),
  },

  // --- SB-617 ---------------------------------------------------------------
  // The check itself runs in the database on pg_cron (deploy_drift_fetch at 07:20,
  // deploy_drift_evaluate at 07:25 UTC). This only reads its latest daily row, so the
  // process audit sees it; a missing or old row comes back stale, never clean.
  deploy_drift_report: {
    mutates: false,
    summary: "SB-617: latest daily deploy-drift result (GitHub Pages vs main, recorded edge deploys vs main); stale if older than 26h.",
    run: async ({ sb }) => {
      const rows = unwrap(await sb.from("activity_log").select("created_at,summary,meta")
        .eq("target_table", "deploy_drift").order("created_at", { ascending: false }).limit(1));
      return deployDriftReport((rows[0] ?? null) as DeployDriftRow | null, new Date());
    },
  },
};

// PARAM_SPECS lives in params.ts so it can be tested; make sure it names only
// real operations. A typo there would otherwise leave an operation reading
// undefined. Failing at boot is loud; failing per request would not be.
for (const op of Object.keys(PARAM_SPECS)) {
  if (!(op in OPERATIONS)) throw new Error(`PARAM_SPECS names unknown operation "${op}"`);
}

// Named bundles. A sweep asks for one of these instead of listing operations.
const BUNDLES: Record<string, string[]> = {
  "process-engineer-daily": [
    "qa_shiftleft_sweep", "review_sla_sweep", "cron_health_check", "backlog_grooming_report",
    "deploy_drift_report",
  ],
  "management-agent-sweep": [
    "agents_missing_chain", "agent_load", "agents_idle_with_queue", "decision_digest",
  ],
  "pm-triage-dispatch": [
    "untriaged_items", "review_queue_aging", "stale_wip", "blocked_items", "awaiting_human",
    "external_waits", "wip_queue", "decision_digest",
  ],
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // SB-440 pattern: validate against the Vault-held token without receiving it.
  {
    const presented = req.headers.get("x-token") ?? "";
    const { data: ok, error } = await sb.rpc("supabrain_sweep_token_matches", { p_token: presented });
    if (error || ok !== true) return new Response("forbidden", { status: 403 });
  }

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch (_) { /* empty body is fine */ }

  // Discovery: a caller with a valid token can ask what exists. This returns
  // names and descriptions only — never a query, never a parameter value.
  if (body.describe === true) {
    return json({
      ok: true,
      operations: Object.fromEntries(
        Object.entries(OPERATIONS).map(([k, v]) =>
          [k, { mutates: v.mutates, summary: v.summary, params: PARAM_SPECS[k] ?? {} }]),
      ),
      bundles: BUNDLES,
      note: "Call with {\"bundle\":\"<name>\"} or {\"operations\":[\"<name>\",…]}. This endpoint accepts no SQL. " +
        "Parameters go in \"params\", either flat ({\"staleDays\":7}) when every operation in the call " +
        "means the same thing by the name, or per operation ({\"stale_wip\":{\"staleDays\":7}}).",
    });
  }

  const dryRun = body.dryRun === true;

  // Resolve the requested work to a list of operation names.
  let names: string[];
  if (typeof body.bundle === "string") {
    const b = BUNDLES[body.bundle];
    if (!b) return json({ ok: false, error: `unknown bundle "${body.bundle}"`, bundles: Object.keys(BUNDLES) }, 400);
    names = b;
  } else if (Array.isArray(body.operations)) {
    names = body.operations.map(String);
  } else {
    return json({ ok: false, error: "specify \"bundle\" or \"operations\"",
                  bundles: Object.keys(BUNDLES), operations: Object.keys(OPERATIONS) }, 400);
  }

  // Reject the whole request if any name is unknown, rather than silently
  // running a subset — a caller that asked for five things and got four
  // should be told, not handed a short report it may read as complete.
  const unknown = names.filter((n) => !(n in OPERATIONS));
  if (unknown.length) {
    return json({ ok: false, error: "unknown operation(s)", unknown, operations: Object.keys(OPERATIONS) }, 400);
  }

  // SB-495: resolve parameters per operation before running anything, so an
  // ambiguous or misspelt parameter refuses the whole request up front.
  const resolved = resolveParams(names, body.params, Object.keys(OPERATIONS));
  if (!resolved.ok) return json({ ok: false, error: resolved.error, ...resolved.detail }, 400);

  const started = Date.now();
  const results: Record<string, unknown> = {};
  const skipped: string[] = [];
  const failed: Record<string, string> = {};

  for (const name of names) {
    const op = OPERATIONS[name];
    if (dryRun && op.mutates) { skipped.push(name); continue; }
    try {
      results[name] = await op.run({ sb, p: resolved.perOp[name] });
    } catch (e) {
      // One failing operation must not lose the others' output: a sweep that
      // reports four findings and one error is more useful than a 500.
      failed[name] = String(e instanceof Error ? e.message : e);
    }
  }

  // A result cut short is named at the top level, not left for the caller to
  // find inside one of a dozen result objects.
  const cut = Object.entries(results)
    .filter(([, r]) => (r as { truncated?: unknown } | null)?.truncated === true)
    .map(([n]) => n);

  return json({
    ok: Object.keys(failed).length === 0,
    complete: Object.keys(failed).length === 0 && cut.length === 0,
    bundle: typeof body.bundle === "string" ? body.bundle : null,
    dryRun,
    ran: Object.keys(results),
    skipped_because_dry_run: skipped,
    failed,
    truncated: cut,
    ...(cut.length ? { warning: `result(s) cut short, counts are not totals: ${cut.join(", ")}` } : {}),
    params_used: Object.fromEntries(
      Object.entries(resolved.perOp).filter(([n, v]) => n in results && Object.keys(v).length)),
    duration_ms: Date.now() - started,
    at: new Date().toISOString(),
    results,
  }, Object.keys(failed).length ? 207 : 200);
});
