// SB-593 / ADR-FLOW-005 D3, D10, D11: pure helpers behind the read-only
// operations external_waits, wip_queue and the wait filter on stale_wip /
// blocked_items. No Deno or Supabase imports, so ops.test.ts imports the code
// that ships, as params.test.ts does for params.ts.

/**
 * PostgREST `.or()` filter that keeps only items NOT waiting on an outside
 * party. The edge treats only a missing key, '' and 'false' as "not waiting".
 * The database classifier (work_item_wait_state) also trims whitespace and
 * lower-cases 'false', so a value of '  ' or 'FALSE' is skipped here but not
 * counted as waiting there; such an item is invisible to both stale_wip and
 * external_waits until the value is cleaned. It never hides a real wait.
 * Expired waits are skipped here too: they come back through external_waits,
 * once, with severity 'escalate'.
 */
export const NOT_WAITING_FILTER =
  "meta->>awaiting_external.is.null,meta->>awaiting_external.eq.false,meta->>awaiting_external.eq.";

/** The edge's own reading of the key, mirroring NOT_WAITING_FILTER exactly. */
export function edgeTreatsAsWaiting(value: unknown): boolean {
  if (value === null || value === undefined) return false;
  const s = String(value);
  return s !== "" && s !== "false";
}

/** Columns external_waits returns from v_external_wait_status. */
export const EXTERNAL_WAIT_FIELDS = [
  "ticket_code", "status", "assignee", "priority", "external_party", "external_ref",
  "clock_expires", "clock_source", "days_to_clock", "project_id",
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
  wait_state: string;
};

export type ExternalWaits = {
  on_track: Array<Omit<ExternalWaitRow, "wait_state">>;
  expired: Array<Omit<ExternalWaitRow, "wait_state">>;
  no_clock: Array<Omit<ExternalWaitRow, "wait_state">>;
  counts: { on_track: number; expired: number; no_clock: number; total: number; unknown_state: number };
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
 * define is counted in unknown_state rather than silently dropped.
 */
export function groupExternalWaits(rows: ExternalWaitRow[]): ExternalWaits {
  const out: ExternalWaits = {
    on_track: [], expired: [], no_clock: [],
    counts: { on_track: 0, expired: 0, no_clock: 0, total: rows.length, unknown_state: 0 },
  };
  for (const { wait_state, ...rest } of rows) {
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
  return (a.blocked_at ?? "\uffff").localeCompare(b.blocked_at ?? "\uffff");
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
