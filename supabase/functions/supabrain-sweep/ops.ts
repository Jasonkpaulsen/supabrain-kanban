// SB-593 / ADR-FLOW-005 D3, D3a, D10, D11: pure helpers behind the read-only
// operations external_waits and wip_queue, and the view the wait-aware list
// operations read. No Deno or Supabase imports, so ops.test.ts imports the code
// that ships, as params.test.ts does for params.ts.

/**
 * SB-602 / ADR-FLOW-005 D3a: the view stale_wip, blocked_items and review_queue_aging
 * read instead of work_items. Its wait_state column is the database classifier
 * (work_item_wait_state), so the edge no longer re-derives "waiting" from
 * meta.awaiting_external and cannot disagree with it on whitespace or case. These
 * operations keep `wait_state is null`: an expired wait is skipped here too and comes
 * back once through external_waits, with severity 'escalate'.
 */
export const OPEN_WORK_VIEW = "v_open_work_wait_state";

/** Columns external_waits returns from v_external_wait_status. */
export const EXTERNAL_WAIT_FIELDS = [
  "ticket_code", "status", "assignee", "priority", "external_party", "external_ref",
  "clock_expires", "clock_source", "days_to_clock", "project_id", "severity", "data_quality_issue",
] as const;

export type ExternalWaitRow = {
  ticket_code: string;
  status: string;
  assignee: string | null;
  priority: string | null;
  external_party: string | null;
  external_ref: string | null;
  clock_expires: string | null;
  clock_source: string | null;
  days_to_clock: number | null;
  project_id: string | null;
  severity: string | null;
  data_quality_issue: string | null;
  wait_state: string;
};

export type ExternalWaits = {
  on_track: Array<Omit<ExternalWaitRow, "wait_state">>;
  expired: Array<Omit<ExternalWaitRow, "wait_state">>;
  no_clock: Array<Omit<ExternalWaitRow, "wait_state">>;
  counts: {
    on_track: number; expired: number; no_clock: number; total: number; unknown_state: number;
    /** SB-603: rows with a data_quality_issue, in any list (an expired one stays severity 'escalate'). */
    data_quality: number;
  };
};

function byClock(a: { days_to_clock: number | null; ticket_code: string },
                 b: { days_to_clock: number | null; ticket_code: string }): number {
  const x = a.days_to_clock ?? Number.POSITIVE_INFINITY;
  const y = b.days_to_clock ?? Number.POSITIVE_INFINITY;
  return x === y ? a.ticket_code.localeCompare(b.ticket_code) : x - y;
}

/**
 * Split v_external_wait_status rows by wait_state. Expired items are sorted
 * most overdue first; on-track by nearest clock. A state the view does not
 * define is counted in unknown_state rather than silently dropped. A row with a
 * data-quality issue (SB-603: invalid clock, non-text party, no clock) stays in its
 * list and is also counted in counts.data_quality.
 */
export function groupExternalWaits(rows: ExternalWaitRow[]): ExternalWaits {
  const out: ExternalWaits = {
    on_track: [], expired: [], no_clock: [],
    counts: { on_track: 0, expired: 0, no_clock: 0, total: rows.length, unknown_state: 0, data_quality: 0 },
  };
  for (const { wait_state, ...rest } of rows) {
    if (rest.data_quality_issue !== null && rest.data_quality_issue !== undefined) out.counts.data_quality++;
    if (wait_state === "waiting_on_track") out.on_track.push(rest);
    else if (wait_state === "external_clock_expired") out.expired.push(rest);
    else if (wait_state === "waiting_no_clock") out.no_clock.push(rest);
    else out.counts.unknown_state++;
  }
  out.on_track.sort(byClock);
  out.expired.sort(byClock);
  out.no_clock.sort((a, b) => a.ticket_code.localeCompare(b.ticket_code));
  out.counts.on_track = out.on_track.length;
  out.counts.expired = out.expired.length;
  out.counts.no_clock = out.no_clock.length;
  return out;
}

/** Columns wip_queue reads from v_wip_queue (pkg-4, SB-598). No ids. */
export const WIP_QUEUE_FIELDS = [
  "ticket_code", "title", "priority", "assignee", "blocked_at", "queue_age",
  "current_wip", "wip_limit", "slot_available", "project_id",
] as const;

export type WipQueueRow = {
  ticket_code: string;
  title: string | null;
  priority: string | null;
  assignee: string | null;
  blocked_at: string | null;
  queue_age: unknown;
  current_wip: number | null;
  wip_limit: number | null;
  slot_available: boolean | null;
  project_id: string | null;
};

export type WipQueue = {
  by_assignee: Record<string, { current_wip: number | null; wip_limit: number | null; slot_available: boolean; items: WipQueueRow[] }>;
  ready: WipQueueRow[];
  counts: { parked: number; assignees: number; ready: number };
};

/** Key used for a parked row with no assignee, so it is grouped, not lost. */
export const UNASSIGNED = "(unassigned)";

const PRIORITY_RANK: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

/** critical, high, medium, low, then anything else; ties by oldest blocked_at. */
export function byPriorityThenAge(a: WipQueueRow, b: WipQueueRow): number {
  const x = PRIORITY_RANK[a.priority ?? ""] ?? 4;
  const y = PRIORITY_RANK[b.priority ?? ""] ?? 4;
  if (x !== y) return x - y;
  return (a.blocked_at ?? LAST).localeCompare(b.blocked_at ?? LAST);
}

// Sorts after any timestamp. Built from its code point rather than written as a
// backslash-u escape, because the deploy path turns such an escape (even one inside a
// comment) into the literal character, and the deployed bytes then stop matching the
// repo (SB-617's ledger compares them).
const LAST = String.fromCharCode(0xffff);

/** SB-617: the deploy-drift check runs daily at 07:25 UTC; a result older than this is stale. */
export const DEPLOY_DRIFT_MAX_AGE_HOURS = 26;

export interface DeployDriftRow {
  created_at: string;
  summary: string | null;
  meta: { violations?: unknown[]; flags?: unknown[]; run_id?: string; checked?: number } | null;
}

/**
 * Shape the latest deploy_drift activity_log row for the daily audit. No row, or a row
 * older than a day and a bit, is reported as stale: silence must not read as clean.
 */
export function deployDriftReport(row: DeployDriftRow | null, now: Date) {
  if (!row) return { found: false, stale: true, note: "no deploy_drift result recorded yet" };
  const ageHours = (now.getTime() - new Date(row.created_at).getTime()) / 3_600_000;
  const violations = row.meta?.violations ?? [];
  const flags = row.meta?.flags ?? [];
  return {
    found: true,
    at: row.created_at,
    age_hours: Math.round(ageHours * 10) / 10,
    stale: !(ageHours <= DEPLOY_DRIFT_MAX_AGE_HOURS),
    summary: row.summary,
    violations_count: violations.length,
    violations,
    flags,
    checked: row.meta?.checked ?? null,
  };
}

/**
 * Group v_wip_queue rows by assignee. The database orders by (assignee,
 * priority, blocked_at), but priority is text there, so within each assignee
 * the rows are re-sorted by priority rank, then oldest blocked_at. `ready`
 * lists rows whose assignee has a free slot (slot_available true), in the
 * same order: the next tickets that can be resumed.
 */
export function groupWipQueue(input: WipQueueRow[]): WipQueue {
  const rows = [...input].sort((a, b) =>
    (a.assignee ?? UNASSIGNED).localeCompare(b.assignee ?? UNASSIGNED) || byPriorityThenAge(a, b));
  const by: WipQueue["by_assignee"] = {};
  const ready: WipQueueRow[] = [];
  for (const row of rows) {
    const key = row.assignee ?? UNASSIGNED;
    const g = by[key] ??= { current_wip: row.current_wip, wip_limit: row.wip_limit, slot_available: false, items: [] };
    g.items.push(row);
    if (row.slot_available === true) {
      g.slot_available = true;
      ready.push(row);
    }
  }
  return { by_assignee: by, ready, counts: { parked: rows.length, assignees: Object.keys(by).length, ready: ready.length } };
}
