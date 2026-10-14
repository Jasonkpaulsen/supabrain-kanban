// SB-593 tests for ops.ts (TC-SB593-6). Imports the module that ships -- not a copy.
//
// Run:  node --experimental-strip-types --test supabase/functions/supabrain-sweep/*.test.ts
//
// Not deployed. index.ts cannot be imported under Node (jsr: imports, Deno.serve),
// so its wiring is checked from its source text: the filter on stale_wip and
// blocked_items, the three new read-only operations and the bundle lists. The
// live half of TC-SB593-6 (describe + a pm-triage-dispatch run) follows the deploy.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  edgeTreatsAsWaiting, EXTERNAL_WAIT_FIELDS, type ExternalWaitRow, groupExternalWaits, groupWipQueue,
  NOT_WAITING_FILTER, UNASSIGNED, WIP_QUEUE_FIELDS, type WipQueueRow,
} from "./ops.ts";

const SRC = readFileSync(new URL("./index.ts", import.meta.url), "utf8");

/** The source of one OPERATIONS entry, from its name to the next top-level entry. */
function opSource(name: string): string {
  const start = SRC.indexOf(`\n  ${name}: {`);
  assert.ok(start >= 0, `operation ${name} not found in index.ts`);
  const next = SRC.slice(start + 1).search(/\n  [a-z_]+: \{|\n\};/);
  return SRC.slice(start, start + 1 + next);
}

function bundle(name: string): string[] {
  const m = SRC.match(new RegExp(`"${name}": \\[([^\\]]*)\\]`));
  assert.ok(m, `bundle ${name} not found`);
  return [...m[1].matchAll(/"([a-z_]+)"/g)].map((x) => x[1]);
}

// --- the wait filter --------------------------------------------------------

test("NOT_WAITING_FILTER keeps exactly null, 'false' and ''", () => {
  assert.equal(NOT_WAITING_FILTER,
    "meta->>awaiting_external.is.null,meta->>awaiting_external.eq.false,meta->>awaiting_external.eq.");
  for (const v of [null, undefined, "", "false"]) assert.equal(edgeTreatsAsWaiting(v), false, `${v}`);
  for (const v of ["NYC Parks Forestry", "true", "yes", "  ", "FALSE"]) assert.equal(edgeTreatsAsWaiting(v), true, `${v}`);
});

test("stale_wip and blocked_items apply the wait filter; the others do not", () => {
  for (const op of ["stale_wip", "blocked_items"]) {
    assert.match(opSource(op), /\.or\(NOT_WAITING_FILTER\)/, `${op} must skip waits`);
  }
  for (const op of ["untriaged_items", "review_queue_aging", "awaiting_human"]) {
    assert.doesNotMatch(opSource(op), /NOT_WAITING_FILTER/, `${op} was not asked to change`);
  }
});

// --- the three new operations -----------------------------------------------

test("external_waits, wip_queue and decision_digest are read-only", () => {
  for (const op of ["external_waits", "wip_queue", "decision_digest"]) {
    assert.match(opSource(op), /mutates: false,/, `${op} must be mutates:false`);
  }
  assert.match(opSource("external_waits"), /from\("v_external_wait_status"\)/);
  assert.match(opSource("wip_queue"), /from\("v_wip_queue"\)/);
  assert.match(opSource("decision_digest"), /rpc\("jason_decision_digest"\)/);
  for (const op of ["external_waits", "wip_queue", "decision_digest"]) {
    assert.doesNotMatch(opSource(op), /\.(insert|update|upsert)\(/, `${op} must not write`);
  }
});

test("bundles: pm-triage-dispatch gains three operations, management-agent-sweep gains the digest", () => {
  assert.deepEqual(bundle("pm-triage-dispatch"), [
    "untriaged_items", "review_queue_aging", "stale_wip", "blocked_items", "awaiting_human",
    "external_waits", "wip_queue", "decision_digest",
  ]);
  assert.deepEqual(bundle("management-agent-sweep"),
    ["agents_missing_chain", "agent_load", "agents_idle_with_queue", "decision_digest"]);
  assert.deepEqual(bundle("process-engineer-daily"),
    ["qa_shiftleft_sweep", "review_sla_sweep", "cron_health_check", "backlog_grooming_report"], "unchanged");
});

test("field lists carry no ids and match the contract", () => {
  assert.deepEqual([...EXTERNAL_WAIT_FIELDS], ["ticket_code", "status", "assignee", "priority", "external_party",
    "external_ref", "clock_expires", "clock_source", "days_to_clock", "project_id"]);
  assert.deepEqual([...WIP_QUEUE_FIELDS], ["ticket_code", "title", "priority", "assignee", "blocked_at", "queue_age",
    "current_wip", "wip_limit", "slot_available", "project_id"]);
  assert.ok(!(EXTERNAL_WAIT_FIELDS as readonly string[]).includes("id"));
  assert.ok(!(WIP_QUEUE_FIELDS as readonly string[]).includes("id"));
});

// --- grouping ---------------------------------------------------------------

function wait(code: string, state: string, days: number | null): ExternalWaitRow {
  return { ticket_code: code, status: "in_progress", assignee: null, priority: "high", external_party: "Agency",
           external_ref: null, clock_expires: null, clock_source: days === null ? null : "meta",
           days_to_clock: days, project_id: "p", wait_state: state };
}

test("groupExternalWaits splits by state, sorts by clock and drops wait_state from rows", () => {
  const g = groupExternalWaits([
    wait("39P-026", "waiting_on_track", 23), wait("X-2", "waiting_on_track", 3),
    wait("X-3", "external_clock_expired", -1), wait("X-4", "external_clock_expired", -9),
    wait("X-5", "waiting_no_clock", null), wait("X-6", "mystery", 1),
  ]);
  assert.deepEqual(g.on_track.map((r) => r.ticket_code), ["X-2", "39P-026"]);
  assert.deepEqual(g.expired.map((r) => r.ticket_code), ["X-4", "X-3"], "most overdue first");
  assert.deepEqual(g.no_clock.map((r) => r.ticket_code), ["X-5"]);
  assert.deepEqual(g.counts, { on_track: 2, expired: 2, no_clock: 1, total: 6, unknown_state: 1 });
  assert.ok(!("wait_state" in g.on_track[0]));
});

test("groupExternalWaits on an empty view", () => {
  const g = groupExternalWaits([]);
  assert.deepEqual(g.counts, { on_track: 0, expired: 0, no_clock: 0, total: 0, unknown_state: 0 });
});

function parked(code: string, assignee: string | null, priority: string, at: string, slot: boolean): WipQueueRow {
  return { ticket_code: code, title: null, priority, assignee, blocked_at: at, queue_age: null,
           current_wip: 5, wip_limit: 5, slot_available: slot, project_id: "p" };
}

test("groupWipQueue groups by assignee, ranks priority, and lists ready rows", () => {
  const g = groupWipQueue([
    parked("A-1", "QA", "low", "2026-10-01", false),
    parked("A-2", "QA", "critical", "2026-10-05", false),
    parked("A-3", "QA", "high", "2026-10-02", false),
    parked("B-1", "Platform", "medium", "2026-10-03", true),
    parked("B-2", "Platform", "medium", "2026-10-01", true),
    parked("C-1", null, "high", "2026-10-04", false),
  ]);
  assert.deepEqual(g.by_assignee.QA.items.map((r) => r.ticket_code), ["A-2", "A-3", "A-1"]);
  assert.deepEqual(g.by_assignee.Platform.items.map((r) => r.ticket_code), ["B-2", "B-1"], "oldest first on a tie");
  assert.equal(g.by_assignee.QA.slot_available, false);
  assert.equal(g.by_assignee.Platform.slot_available, true);
  assert.deepEqual(g.by_assignee[UNASSIGNED].items.map((r) => r.ticket_code), ["C-1"]);
  assert.deepEqual(g.ready.map((r) => r.ticket_code), ["B-2", "B-1"]);
  assert.deepEqual(g.counts, { parked: 6, assignees: 3, ready: 2 });
});
