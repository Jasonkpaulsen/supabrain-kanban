// SB-593 tests for ops.ts (TC-SB593-6), extended by SB-601/602/603 (TC-SB601-1,
// TC-SB602-1, ADR-FLOW-005 amendment 1). Imports the module that ships -- not a copy.
//
// Run:  node --experimental-strip-types --test supabase/functions/supabrain-sweep/*.test.ts
//
// Not deployed. index.ts cannot be imported under Node (jsr: imports, Deno.serve),
// so its wiring is checked from its source text: which operations read the
// wait-state view, the three read-only operations and the bundle lists. The live
// half of TC-SB593-6 (describe + a pm-triage-dispatch run) follows the deploy.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  EXTERNAL_WAIT_FIELDS, type ExternalWaitRow, groupExternalWaits, groupWipQueue,
  OPEN_WORK_VIEW, UNASSIGNED, WIP_QUEUE_FIELDS, type WipQueueRow,
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

// --- the wait rule lives in the database (SB-601, SB-602) --------------------

const WAIT_AWARE = ["stale_wip", "blocked_items", "review_queue_aging"];

test("the wait-aware operations read the database classification and keep wait_state is null", () => {
  assert.equal(OPEN_WORK_VIEW, "v_open_work_wait_state");
  for (const op of WAIT_AWARE) {
    const src = opSource(op);
    assert.match(src, /from\(OPEN_WORK_VIEW\)/, `${op} must read the wait-state view`);
    assert.match(src, /\.is\("wait_state", null\)/, `${op} must skip waits`);
    assert.doesNotMatch(src, /from\("work_items"\)/, `${op} must not read work_items directly`);
  }
});

test("no operation re-derives the wait rule from meta", () => {
  const start = SRC.indexOf("const OPERATIONS");
  const end = SRC.indexOf("\n};\n", start);
  assert.ok(start >= 0 && end > start, "OPERATIONS block not found");
  const ops = SRC.slice(start, end);
  assert.doesNotMatch(ops, /awaiting_external/, "the classifier is work_item_wait_state, not the edge");
  assert.doesNotMatch(ops, /NOT_WAITING_FILTER/);
  for (const op of ["untriaged_items", "awaiting_human"]) {
    assert.doesNotMatch(opSource(op), /wait_state/, `${op} was not asked to change`);
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
    "external_ref", "clock_expires", "clock_source", "days_to_clock", "project_id", "severity", "data_quality_issue"]);
  assert.deepEqual([...WIP_QUEUE_FIELDS], ["ticket_code", "title", "priority", "assignee", "blocked_at", "queue_age",
    "current_wip", "wip_limit", "slot_available", "project_id"]);
  assert.ok(!(EXTERNAL_WAIT_FIELDS as readonly string[]).includes("id"));
  assert.ok(!(WIP_QUEUE_FIELDS as readonly string[]).includes("id"));
});

// --- grouping ---------------------------------------------------------------

function wait(code: string, state: string, days: number | null, issue: string | null = null): ExternalWaitRow {
  const severity = state === "external_clock_expired" ? "escalate"
    : issue !== null || state !== "waiting_on_track" ? "data_quality" : "info";
  return { ticket_code: code, status: "in_progress", assignee: null, priority: "high", external_party: "Agency",
           external_ref: null, clock_expires: null, clock_source: days === null ? null : "meta",
           days_to_clock: days, project_id: "p", severity, data_quality_issue: issue, wait_state: state };
}

test("groupExternalWaits splits by state, sorts by clock and drops wait_state from rows", () => {
  const g = groupExternalWaits([
    wait("39P-026", "waiting_on_track", 23), wait("X-2", "waiting_on_track", 3),
    wait("X-3", "external_clock_expired", -1), wait("X-4", "external_clock_expired", -9),
    wait("X-5", "waiting_no_clock", null, "no_clock"), wait("X-6", "mystery", 1),
  ]);
  assert.deepEqual(g.on_track.map((r) => r.ticket_code), ["X-2", "39P-026"]);
  assert.deepEqual(g.expired.map((r) => r.ticket_code), ["X-4", "X-3"], "most overdue first");
  assert.deepEqual(g.no_clock.map((r) => r.ticket_code), ["X-5"]);
  assert.deepEqual(g.counts, { on_track: 2, expired: 2, no_clock: 1, total: 6, unknown_state: 1, data_quality: 2 });
  assert.ok(!("wait_state" in g.on_track[0]));
  assert.equal(g.no_clock[0].data_quality_issue, "no_clock");
});

test("groupExternalWaits on an empty view", () => {
  const g = groupExternalWaits([]);
  assert.deepEqual(g.counts, { on_track: 0, expired: 0, no_clock: 0, total: 0, unknown_state: 0, data_quality: 0 });
});

test("SB-603: a data-quality issue keeps the row in its list and is counted", () => {
  const g = groupExternalWaits([
    wait("Q-1", "waiting_on_track", 4, "invalid_clock"),
    wait("Q-2", "external_clock_expired", -2, "invalid_clock"),
    wait("Q-3", "waiting_on_track", 9),
  ]);
  assert.deepEqual(g.on_track.map((r) => [r.ticket_code, r.severity, r.data_quality_issue]),
    [["Q-1", "data_quality", "invalid_clock"], ["Q-3", "info", null]]);
  assert.deepEqual(g.expired.map((r) => [r.ticket_code, r.severity]), [["Q-2", "escalate"]],
    "a lapsed clock outranks a data-quality issue");
  assert.equal(g.counts.data_quality, 1);
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
