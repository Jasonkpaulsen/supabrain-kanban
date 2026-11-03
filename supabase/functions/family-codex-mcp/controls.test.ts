// TC-SB600-6: family-codex-mcp prechecks before and records after every tool call.
//
// Behavioural tests over controls.ts with a fake RPC, plus source-level checks that
// index.ts routes every tools/call through guardedCall. Run in CI by function-tests.yml:
//   node --experimental-strip-types --test supabase/functions/family-codex-mcp/controls.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { auditBody, guardedCall, precheck, PRECHECK_UNAVAILABLE, UNKNOWN_TOOL, type Rpc } from "./controls.ts";

const CONN = "11111111-2222-3333-4444-555555555555";
const PROJECT = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const TRACE = "99999999-8888-7777-6666-555555555555";
const RECORD_TYPES = ["medication", "care_plan"];

type Call = { fn: string; body: Record<string, unknown> };

function fakeRpc(opts: { verdict?: unknown; precheckThrows?: boolean; recordThrows?: boolean } = {}) {
  const calls: Call[] = [];
  const rpc: Rpc = async (fn, body) => {
    calls.push({ fn, body });
    if (fn === "external_connection_precheck") {
      if (opts.precheckThrows) throw new Error("db down");
      return "verdict" in opts ? opts.verdict : [{ allowed: true, reason_code: null, retry_after_seconds: null }];
    }
    if (fn === "external_connection_record") {
      if (opts.recordThrows) throw new Error("audit down");
      return "row-id";
    }
    throw new Error(`unexpected rpc ${fn}`);
  };
  return { rpc, calls };
}

const denyClassify = (e: unknown) => ({ outcome: "denied" as const, reason_code: (e as { code?: string }).code ?? "error" });

function input(rpc: Rpc, run: () => Promise<unknown>, extra: Record<string, unknown> = {}) {
  return { rpc, connectionId: CONN, toolName: "list_family_records", readOnly: true,
    args: { record_type: "medication", project_id: PROJECT }, recordTypes: RECORD_TYPES, traceId: TRACE,
    run, classify: denyClassify, ...extra };
}

test("allowed call: precheck first, tool runs, one allowed record with the row count", async () => {
  const { rpc, calls } = fakeRpc();
  let ran = 0;
  const g = await guardedCall(input(rpc, async () => { ran++; assert.equal(calls.length, 1, "precheck happens before the tool"); return { count: 3, records: [] }; }));
  assert.equal(ran, 1);
  assert.equal(g.outcome, "allowed");
  assert.equal(g.audited, true);
  assert.deepEqual(calls.map((c) => c.fn), ["external_connection_precheck", "external_connection_record"]);
  assert.deepEqual(calls[0].body, { p_connection_id: CONN, p_tool_name: "list_family_records" });
  assert.deepEqual(calls[1].body, {
    p_connection_id: CONN, p_tool_name: "list_family_records", p_operation: "read", p_outcome: "allowed",
    p_reason_code: null, p_resource_name: "medication", p_project_id: PROJECT, p_result_rows: 3, p_trace_id: TRACE,
  });
});

test("precheck refusal: the tool never runs and a denied row carries the reason", async () => {
  const { rpc, calls } = fakeRpc({ verdict: [{ allowed: false, reason_code: "rate_limited", retry_after_seconds: 120 }] });
  let ran = 0;
  const g = await guardedCall(input(rpc, async () => { ran++; return {}; }));
  assert.equal(ran, 0);
  assert.equal(g.outcome, "denied");
  assert.equal(g.verdict.retry_after_seconds, 120);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].body.p_outcome, "denied");
  assert.equal(calls[1].body.p_reason_code, "rate_limited");
});

test("precheck that cannot be read fails closed", async () => {
  for (const opts of [{ precheckThrows: true }, { verdict: [] }, { verdict: [{ allowed: "yes" }] }, { verdict: null }]) {
    const { rpc } = fakeRpc(opts);
    let ran = 0;
    const g = await guardedCall(input(rpc, async () => { ran++; return {}; }));
    assert.equal(ran, 0, JSON.stringify(opts));
    assert.equal(g.verdict.allowed, false);
    assert.equal(g.reason_code, PRECHECK_UNAVAILABLE);
  }
});

test("tool error: recorded with the classified outcome and code, error passed back", async () => {
  const { rpc, calls } = fakeRpc();
  const boom = Object.assign(new Error("No such record"), { code: "not_found" });
  const g = await guardedCall(input(rpc, async () => { throw boom; }));
  assert.equal(g.outcome, "denied");
  assert.equal(g.error, boom);
  assert.equal(calls[1].body.p_outcome, "denied");
  assert.equal(calls[1].body.p_reason_code, "not_found");

  const e2 = await guardedCall(input(fakeRpc().rpc, async () => { throw new Error("x"); },
    { classify: () => ({ outcome: "error" as const, reason_code: "timeout" }) }));
  assert.equal(e2.outcome, "error");
});

test("audit failure never changes the answer", async () => {
  const { rpc } = fakeRpc({ recordThrows: true });
  const g = await guardedCall(input(rpc, async () => ({ count: 1 })));
  assert.equal(g.outcome, "allowed");
  assert.deepEqual(g.result, { count: 1 });
  assert.equal(g.audited, false);

  const boom = Object.assign(new Error("nope"), { code: "forbidden" });
  const g2 = await guardedCall(input(fakeRpc({ recordThrows: true }).rpc, async () => { throw boom; }));
  assert.equal(g2.outcome, "denied");
  assert.equal(g2.error, boom);
  assert.equal(g2.audited, false);
});

test("nothing from the arguments reaches the audit body except enum record_type and UUID project_id", () => {
  const b = auditBody({
    connectionId: CONN, toolName: "create_family_record", readOnly: false,
    args: { record_type: "medications; select 1", project_id: "not-a-uuid", payload: { name: "SECRET-SENTINEL" }, title: "SECRET-SENTINEL" },
    recordTypes: RECORD_TYPES, outcome: "denied", reasonCode: "The database refused this request", traceId: TRACE,
  });
  assert.equal(JSON.stringify(b).includes("SECRET-SENTINEL"), false);
  assert.equal(b.p_resource_name, null);
  assert.equal(b.p_project_id, null);
  assert.equal(b.p_reason_code, "error", "a non-identifier reason is replaced, not passed through");
  assert.equal(b.p_operation, "write");
  assert.deepEqual(Object.keys(b).sort(), ["p_connection_id", "p_operation", "p_outcome", "p_project_id", "p_reason_code",
    "p_resource_name", "p_result_rows", "p_tool_name", "p_trace_id"]);
});

test("unknown or malformed tool names and result counts are normalised", () => {
  const b = auditBody({ connectionId: CONN, toolName: "../etc", readOnly: true, args: {}, recordTypes: RECORD_TYPES,
    outcome: "denied", reasonCode: "unknown_tool", result: { count: 50_000 }, traceId: "bad" });
  assert.equal(b.p_tool_name, UNKNOWN_TOOL);
  assert.equal(b.p_result_rows, 1000);
  assert.equal(b.p_trace_id, null);
  assert.equal(auditBody({ connectionId: CONN, toolName: "x", readOnly: true, args: {}, recordTypes: [], outcome: "allowed",
    reasonCode: null, result: { count: 2.5 }, traceId: TRACE }).p_result_rows, null);
});

test("precheck passes the verdict through and sanitises its reason", async () => {
  const v = await precheck(fakeRpc({ verdict: [{ allowed: false, reason_code: "connection_disabled", retry_after_seconds: null }] }).rpc, CONN, "t");
  assert.deepEqual(v, { allowed: false, reason_code: "connection_disabled", retry_after_seconds: null });
  const w = await precheck(fakeRpc({ verdict: [{ allowed: false, reason_code: "Bad Reason!" }] }).rpc, CONN, "t");
  assert.equal(w.reason_code, "denied");
});

// ------------------------------------------------------------------ index.ts wiring
const SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "index.ts"), "utf8");

test("index.ts: every tools/call goes through guardedCall, and callTool is reached only from it", () => {
  const callSites = SRC.match(/callTool\(caller,/g) ?? [];   // call sites, not the definition
  assert.equal(callSites.length, 1, "exactly one call site for callTool");
  assert.match(SRC, /run: \(\) => callTool\(caller, requested, args\)/);
  assert.match(SRC, /await guardedCall\(\{/);
});

test("index.ts: the audit table is never addressed directly, only through the RPC", () => {
  assert.equal(/\/external_connection_audit_log/.test(SRC), false);
  assert.equal(/\/external_connection_limits/.test(SRC), false);
});

test("index.ts: the connection id comes from the verified connection row", () => {
  assert.match(SRC, /caller\.connectionId = String\(conn\.id\)/);
});
