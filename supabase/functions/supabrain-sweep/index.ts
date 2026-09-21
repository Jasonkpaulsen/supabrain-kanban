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

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

const MAX_ROWS = 500;          // hard cap on any single read
const OPEN = ["backlog", "todo", "in_progress"];

type Ctx = { sb: SupabaseClient; p: Record<string, unknown> };
type Op = {
  mutates: boolean;
  summary: string;
  run: (c: Ctx) => Promise<unknown>;
};

/** Coerce a caller-supplied integer into a declared range. Never trusts input. */
function int(p: Record<string, unknown>, key: string, def: number, lo: number, hi: number): number {
  const v = p[key];
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  if (!Number.isFinite(n)) return def;
  return Math.min(hi, Math.max(lo, Math.trunc(n)));
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
    mutates: false,
    summary: "public.backlog_grooming_report(p_stale_days) — backlog age report.",
    run: async ({ sb, p }) =>
      unwrap(await sb.rpc("backlog_grooming_report", { p_stale_days: int(p, "staleDays", 45, 1, 365) })),
  },

  // --- management-agent-sweep ----------------------------------------------
  agents_missing_chain: {
    mutates: false,
    summary: "SB-240: automation-enabled agents with no reporting line, which breaks coverage checks.",
    run: async ({ sb }) => {
      const raw = unwrap(await sb.from("agents")
        .select("id,name,status,meta,automation_enabled,reports_to_agent_id,reports_to_human,escalation_ceiling")
        .eq("automation_enabled", true)
        .is("reports_to_agent_id", null)
        .is("reports_to_human", null)
        .limit(MAX_ROWS)) as Array<Record<string, unknown>>;
      const rows = liveAgents(raw).map(({ meta: _meta, ...rest }) => rest);
      return { count: rows.length, excluded_archived_or_fixture: raw.length - rows.length, agents: rows };
    },
  },
  agent_load: {
    mutates: false,
    summary: "Open items per agent against max_concurrent_tasks; flags over-capacity.",
    run: async ({ sb }) => {
      const agents = liveAgents(unwrap(await sb.from("agents")
        .select("id,name,status,meta,max_concurrent_tasks,automation_enabled,last_run_at")
        .limit(MAX_ROWS)) as Array<Record<string, unknown>>);
      const items = unwrap(await sb.from("work_items")
        .select("assigned_agent_id")
        .in("status", OPEN)
        .not("assigned_agent_id", "is", null)
        .limit(5000)) as Array<{ assigned_agent_id: string }>;
      const counts: Record<string, number> = {};
      for (const it of items) counts[it.assigned_agent_id] = (counts[it.assigned_agent_id] ?? 0) + 1;
      const rows = agents
        .map((a) => {
          const open = counts[a.id as string] ?? 0;
          const cap = (a.max_concurrent_tasks as number | null) ?? 5;
          return { agent: a.name, open, cap, over_capacity: open > cap, last_run_at: a.last_run_at };
        })
        .filter((r) => r.open > 0)
        .sort((x, y) => y.open - x.open);
      return { count: rows.length, over_capacity: rows.filter((r) => r.over_capacity).length, agents: rows };
    },
  },
  agents_idle_with_queue: {
    mutates: false,
    summary: "Agents holding open work that have not run in idleDays.",
    run: async ({ sb, p }) => {
      const cutoff = isoDaysAgo(int(p, "idleDays", 7, 1, 90));
      const agents = liveAgents(unwrap(await sb.from("agents")
        .select("id,name,status,meta,last_run_at").limit(MAX_ROWS)) as Array<Record<string, unknown>>);
      const items = unwrap(await sb.from("work_items")
        .select("assigned_agent_id").in("status", OPEN)
        .not("assigned_agent_id", "is", null).limit(5000)) as Array<{ assigned_agent_id: string }>;
      const counts: Record<string, number> = {};
      for (const it of items) counts[it.assigned_agent_id] = (counts[it.assigned_agent_id] ?? 0) + 1;
      const rows = agents
        .filter((a) => (counts[a.id as string] ?? 0) > 0)
        .filter((a) => !a.last_run_at || (a.last_run_at as string) < cutoff)
        .map((a) => ({ agent: a.name, open: counts[a.id as string], last_run_at: a.last_run_at }));
      return { cutoff, count: rows.length, agents: rows };
    },
  },

  // --- pm-triage-dispatch ---------------------------------------------------
  untriaged_items: {
    mutates: false,
    summary: "Non-archived backlog items with neither an assignee nor an assigned agent.",
    run: async ({ sb }) => {
      const rows = unwrap(await sb.from("work_items")
        .select("ticket_code,title,type,priority,project_id,created_at")
        .eq("archived", false)
        .eq("status", "backlog")
        .is("assigned_agent_id", null)
        .is("assignee", null)
        .order("created_at", { ascending: true })
        .limit(MAX_ROWS)) as unknown[];
      return { count: rows.length, items: rows };
    },
  },
  review_queue_aging: {
    mutates: false,
    summary: "Items in review longer than ageHours.",
    run: async ({ sb, p }) => {
      const hours = int(p, "ageHours", 48, 1, 24 * 90);
      const rows = unwrap(await sb.from("work_items")
        .select("ticket_code,title,assignee,priority,review_entered_at,project_id")
        .eq("archived", false)
        .eq("status", "review")
        .lt("review_entered_at", isoHoursAgo(hours))
        .order("review_entered_at", { ascending: true })
        .limit(MAX_ROWS)) as unknown[];
      return { age_hours: hours, count: rows.length, items: rows };
    },
  },
  stale_wip: {
    mutates: false,
    summary: "in_progress items untouched for staleDays.",
    run: async ({ sb, p }) => {
      const days = int(p, "staleDays", 3, 1, 365);
      const rows = unwrap(await sb.from("work_items")
        .select("ticket_code,title,assignee,priority,updated_at,project_id")
        .eq("archived", false)
        .eq("status", "in_progress")
        .lt("updated_at", isoDaysAgo(days))
        .order("updated_at", { ascending: true })
        .limit(MAX_ROWS)) as unknown[];
      return { stale_days: days, count: rows.length, items: rows };
    },
  },
  blocked_items: {
    mutates: false,
    summary: "blocked / on_hold items untouched for staleDays.",
    run: async ({ sb, p }) => {
      const days = int(p, "staleDays", 3, 1, 365);
      const rows = unwrap(await sb.from("work_items")
        .select("ticket_code,title,status,assignee,priority,updated_at,project_id")
        .eq("archived", false)
        .in("status", ["blocked", "on_hold"])
        .lt("updated_at", isoDaysAgo(days))
        .order("updated_at", { ascending: true })
        .limit(MAX_ROWS)) as unknown[];
      return { stale_days: days, count: rows.length, items: rows };
    },
  },
  awaiting_human: {
    mutates: false,
    summary: "Items parked on a person: status awaiting_jason, or L3+ not yet approved.",
    run: async ({ sb }) => {
      const parked = unwrap(await sb.from("work_items")
        .select("ticket_code,title,status,priority,updated_at,project_id")
        .eq("archived", false).eq("status", "awaiting_jason")
        .order("updated_at", { ascending: true }).limit(MAX_ROWS)) as unknown[];
      const unapproved = unwrap(await sb.from("work_items")
        .select("ticket_code,title,status,authority_level,approval_status,project_id")
        .eq("archived", false).gte("authority_level", 3)
        .neq("approval_status", "approved")
        .in("status", OPEN).limit(MAX_ROWS)) as unknown[];
      return { awaiting_jason: parked, unapproved_l3_plus: unapproved,
               count: (parked as unknown[]).length + (unapproved as unknown[]).length };
    },
  },
};

// Named bundles. A sweep asks for one of these instead of listing operations.
const BUNDLES: Record<string, string[]> = {
  "process-engineer-daily": [
    "qa_shiftleft_sweep", "review_sla_sweep", "cron_health_check", "backlog_grooming_report",
  ],
  "management-agent-sweep": [
    "agents_missing_chain", "agent_load", "agents_idle_with_queue",
  ],
  "pm-triage-dispatch": [
    "untriaged_items", "review_queue_aging", "stale_wip", "blocked_items", "awaiting_human",
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
        Object.entries(OPERATIONS).map(([k, v]) => [k, { mutates: v.mutates, summary: v.summary }]),
      ),
      bundles: BUNDLES,
      note: "Call with {\"bundle\":\"<name>\"} or {\"operations\":[\"<name>\",…]}. This endpoint accepts no SQL.",
    });
  }

  const dryRun = body.dryRun === true;
  const params = (body.params && typeof body.params === "object" ? body.params : {}) as Record<string, unknown>;

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

  const started = Date.now();
  const results: Record<string, unknown> = {};
  const skipped: string[] = [];
  const failed: Record<string, string> = {};

  for (const name of names) {
    const op = OPERATIONS[name];
    if (dryRun && op.mutates) { skipped.push(name); continue; }
    try {
      results[name] = await op.run({ sb, p: params });
    } catch (e) {
      // One failing operation must not lose the others' output: a sweep that
      // reports four findings and one error is more useful than a 500.
      failed[name] = String(e instanceof Error ? e.message : e);
    }
  }

  return json({
    ok: Object.keys(failed).length === 0,
    bundle: typeof body.bundle === "string" ? body.bundle : null,
    dryRun,
    ran: Object.keys(results),
    skipped_because_dry_run: skipped,
    failed,
    duration_ms: Date.now() - started,
    at: new Date().toISOString(),
    results,
  }, Object.keys(failed).length ? 207 : 200);
});
