// SB-495 tests for params.ts. Imports the module that ships -- not a copy.
//
// Run:  node --experimental-strip-types --test supabase/functions/supabrain-sweep/params.test.ts
//
// Not deployed: only index.ts and params.ts are sent to the platform.

import { test } from "node:test";
import assert from "node:assert/strict";
import { PARAM_SPECS, resolveParams, truncated } from "./params.ts";

// The operation names index.ts ships, as of SB-495. Only used to tell a
// per-operation block apart from a flat parameter.
const ALL_OPS = [
  "ping", "qa_shiftleft_sweep", "review_sla_sweep", "cron_health_check", "backlog_grooming_report",
  "agents_missing_chain", "agent_load", "agents_idle_with_queue",
  "untriaged_items", "review_queue_aging", "stale_wip", "blocked_items", "awaiting_human",
];
const PM_TRIAGE = ["untriaged_items", "review_queue_aging", "stale_wip", "blocked_items", "awaiting_human"];

function ok(r: ReturnType<typeof resolveParams>) {
  assert.equal(r.ok, true, r.ok ? "" : `expected ok, got: ${r.error}`);
  return (r as { ok: true; perOp: Record<string, Record<string, number>> }).perOp;
}
function refused(r: ReturnType<typeof resolveParams>, pattern: RegExp) {
  assert.equal(r.ok, false, "expected the request to be refused");
  assert.match((r as { error: string }).error, pattern);
  return (r as { detail: Record<string, unknown> }).detail;
}

// --- the defect, as the architect reproduced it -----------------------------

test("the SB-482 review's call is refused: staleDays means two things here", () => {
  const detail = refused(
    resolveParams(["backlog_grooming_report", "stale_wip"], { staleDays: 2 }, ALL_OPS),
    /means different things/,
  );
  const meanings = detail.meanings as Record<string, string[]>;
  assert.equal(Object.keys(meanings).length, 2);
  assert.deepEqual(Object.values(meanings).flat().sort(), ["backlog_grooming_report", "stale_wip"]);
});

test("the same call per operation tunes only the operation named", () => {
  const p = ok(resolveParams(["backlog_grooming_report", "stale_wip"],
                             { stale_wip: { staleDays: 2 } }, ALL_OPS));
  assert.equal(p.stale_wip.staleDays, 2);
  assert.equal(p.backlog_grooming_report.staleDays, 45, "the grooming report keeps its own default");
});

test("per-operation values for both operations in one call", () => {
  const p = ok(resolveParams(["backlog_grooming_report", "stale_wip"],
                             { backlog_grooming_report: { staleDays: 60 }, stale_wip: { staleDays: 5 } }, ALL_OPS));
  assert.equal(p.backlog_grooming_report.staleDays, 60);
  assert.equal(p.stale_wip.staleDays, 5);
});

// --- flat names still work where they are unambiguous -----------------------

test("pm-triage-dispatch: a flat staleDays tunes stale_wip and blocked_items together", () => {
  const p = ok(resolveParams(PM_TRIAGE, { staleDays: 7 }, ALL_OPS));
  assert.equal(p.stale_wip.staleDays, 7);
  assert.equal(p.blocked_items.staleDays, 7);
  assert.equal(p.review_queue_aging.ageHours, 48, "untouched parameters keep their defaults");
  assert.deepEqual(p.untriaged_items, {});
});

test("a single operation with a flat parameter behaves as before", () => {
  const p = ok(resolveParams(["stale_wip"], { staleDays: 7 }, ALL_OPS));
  assert.equal(p.stale_wip.staleDays, 7);
});

test("no params at all gives every operation its defaults", () => {
  for (const raw of [undefined, null, {}]) {
    const p = ok(resolveParams(["backlog_grooming_report", "stale_wip", "agents_idle_with_queue"], raw, ALL_OPS));
    assert.equal(p.backlog_grooming_report.staleDays, 45);
    assert.equal(p.stale_wip.staleDays, 3);
    assert.equal(p.agents_idle_with_queue.idleDays, 7);
  }
});

test("a per-operation block overrides a flat value for that operation only", () => {
  const p = ok(resolveParams(PM_TRIAGE, { staleDays: 7, blocked_items: { staleDays: 14 } }, ALL_OPS));
  assert.equal(p.stale_wip.staleDays, 7);
  assert.equal(p.blocked_items.staleDays, 14);
});

// --- things that used to be ignored silently are now refused ----------------

test("a misspelt parameter is refused, not defaulted", () => {
  const detail = refused(resolveParams(["stale_wip"], { staleday: 7 }, ALL_OPS), /unknown parameter "staleday"/);
  assert.deepEqual(detail.accepted, ["staleDays"]);
});

test("a real parameter that no operation in this call reads is refused", () => {
  refused(resolveParams(["stale_wip"], { idleDays: 3 }, ALL_OPS), /unknown parameter "idleDays"/);
});

test("non-numeric values are refused, flat and per operation", () => {
  refused(resolveParams(["stale_wip"], { staleDays: "abc" }, ALL_OPS), /must be a number/);
  refused(resolveParams(["stale_wip"], { staleDays: "" }, ALL_OPS), /must be a number/);
  refused(resolveParams(["stale_wip"], { staleDays: null }, ALL_OPS), /must be a number/);
  refused(resolveParams(["stale_wip"], { stale_wip: { staleDays: true } }, ALL_OPS), /must be a number/);
});

test("a numeric string is accepted, as it was before", () => {
  const p = ok(resolveParams(["stale_wip"], { staleDays: "10" }, ALL_OPS));
  assert.equal(p.stale_wip.staleDays, 10);
});

test("a block for an operation that is not in the call is refused", () => {
  const detail = refused(resolveParams(["stale_wip"], { blocked_items: { staleDays: 5 } }, ALL_OPS),
                         /not in this call/);
  assert.equal(detail.operation, "blocked_items");
});

test("a block with a parameter its operation does not have is refused", () => {
  refused(resolveParams(["stale_wip"], { stale_wip: { ageHours: 5 } }, ALL_OPS),
          /has no parameter "ageHours"/);
});

test("a block that is not an object is refused", () => {
  refused(resolveParams(["stale_wip"], { stale_wip: 5 }, ALL_OPS), /must be an object/);
});

test("params that are not an object are refused", () => {
  refused(resolveParams(["stale_wip"], [1, 2], ALL_OPS), /params must be an object/);
  refused(resolveParams(["stale_wip"], "staleDays=2", ALL_OPS), /params must be an object/);
});

// --- clamping is kept, and applied per operation's own range ----------------

test("out-of-range values are clamped to the operation's range and truncated to integers", () => {
  assert.equal(ok(resolveParams(["stale_wip"], { staleDays: 9999 }, ALL_OPS)).stale_wip.staleDays, 365);
  assert.equal(ok(resolveParams(["stale_wip"], { staleDays: 0 }, ALL_OPS)).stale_wip.staleDays, 1);
  assert.equal(ok(resolveParams(["stale_wip"], { staleDays: 2.9 }, ALL_OPS)).stale_wip.staleDays, 2);
  assert.equal(ok(resolveParams(["agents_idle_with_queue"], { idleDays: 500 }, ALL_OPS))
    .agents_idle_with_queue.idleDays, 90);
});

// --- the table itself -------------------------------------------------------

test("every declared parameter has a meaning and a default inside its range", () => {
  for (const [op, params] of Object.entries(PARAM_SPECS)) {
    assert.ok(ALL_OPS.includes(op), `${op} is not a shipped operation`);
    for (const [k, s] of Object.entries(params)) {
      assert.ok(s.meaning.length > 0, `${op}.${k} has no meaning`);
      assert.ok(s.lo <= s.def && s.def <= s.hi, `${op}.${k} default ${s.def} outside [${s.lo}, ${s.hi}]`);
    }
  }
});

test("the flat names the three bundles could send are unambiguous within each bundle", () => {
  const bundles: Record<string, string[]> = {
    "process-engineer-daily": ["qa_shiftleft_sweep", "review_sla_sweep", "cron_health_check", "backlog_grooming_report"],
    "management-agent-sweep": ["agents_missing_chain", "agent_load", "agents_idle_with_queue"],
    "pm-triage-dispatch": PM_TRIAGE,
  };
  for (const [name, ops] of Object.entries(bundles)) {
    const flatNames = new Set(ops.flatMap((op) => Object.keys(PARAM_SPECS[op] ?? {})));
    for (const k of flatNames) {
      const r = resolveParams(ops, { [k]: 5 }, ALL_OPS);
      assert.equal(r.ok, true, `${name}: flat "${k}" should be accepted`);
    }
  }
});

// --- truncation -------------------------------------------------------------

test("truncated() compares the exact total with what came back", () => {
  assert.equal(truncated(500, 501, 500), true);
  assert.equal(truncated(500, 500, 500), false, "a full page that is also the whole set is complete");
  assert.equal(truncated(101, 101, 500), false);
  assert.equal(truncated(1000, 1289, 5000), true, "a server row cap below the requested limit is caught");
});

test("without a total, a page as long as the limit is treated as cut", () => {
  assert.equal(truncated(500, null, 500), true);
  assert.equal(truncated(499, null, 500), false);
});
