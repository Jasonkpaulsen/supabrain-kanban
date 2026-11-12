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

// ------------------------------------------------------------------ v6 (SB-825/826/827)
// S-1 is the three checks above, unchanged.

// The source of one `case "<name>":` branch of callTool, up to the next case/default.
function branch(name: string): string {
  const start = SRC.indexOf(`case "${name}":`);
  assert.ok(start >= 0, `case ${name}`);
  const rest = SRC.slice(start + 1);
  const next = rest.search(/\n    (case "|default:)/);
  return SRC.slice(start, start + 1 + (next < 0 ? rest.length : next));
}

test("S-2 update_work_item and the family-record branch validate before any rest( call", () => {
  for (const name of ["update_work_item", "create_work_item", "update_family_record"]) {
    const b = branch(name);
    const v = b.indexOf("validateFields(");
    const r = b.indexOf("rest(caller");
    const am = b.indexOf("assertMember(");
    assert.ok(v >= 0, `${name} calls validateFields`);
    assert.ok(r > v, `${name}: validateFields before rest`);
    if (am >= 0) assert.ok(am > v, `${name}: validateFields before assertMember`);
  }
  // create_family_record falls through to the update_family_record body
  assert.match(SRC, /case "create_family_record":\n    case "update_family_record": \{/);
  const fam = branch("update_family_record");
  assert.ok(fam.indexOf("validateFields(") < fam.indexOf("regimenFields &&"), "validation precedes the regimen guard");
  assert.match(fam, /textLen\(a\.instruction_source as string, LIMITS\.INSTRUCTION_SOURCE\)/);
  assert.match(branch("set_work_item_labels"), /checkLabelIds\(a\.label_ids\)/);
});

test("S-3 the three uncapped list tools now call capRows; list_family_projects bounds its fetch", () => {
  for (const name of ["list_family_projects", "list_family_agents", "list_my_family_agent_sessions"]) {
    assert.match(branch(name), /capRows\(/, name);
    assert.match(branch(name), /truncated/, name);
  }
  assert.match(branch("list_family_projects"), /&limit=\$\{LIMITS\.LIST_CAP \+ 1\}/);
  // Fetch cap + 1 so exactly 1,000 pairs is not reported as truncated (capRows contract).
  assert.match(branch("list_family_agents"), /\?limit=\$\{LIMITS\.AGENT_PAIRS_FETCH \+ 1\}/);
  assert.match(branch("list_family_agents"), /capRows\(fetched, LIMITS\.AGENT_PAIRS_FETCH\)/);
  assert.match(branch("list_family_agents"), /truncated: agents\.truncated \|\| pairs\.truncated/);
  assert.doesNotMatch(branch("list_family_agents"), />= LIMITS\.AGENT_PAIRS_FETCH/);
  assert.match(branch("list_my_family_agent_sessions"), /\?limit=\$\{LIMITS\.LIST_CAP \+ 1\}/);
});

test("S-4 every -32001 reply is preceded by the refusal audit; verifiedToken never logged", () => {
  const re = /return json\(\{[^\n]*-32001/g;
  let m: RegExpExecArray | null;
  let n = 0;
  while ((m = re.exec(SRC))) {
    n++;
    const before = SRC.slice(0, m.index);
    const lastReturn = before.lastIndexOf("return ");
    const lastAudit = before.lastIndexOf("queueAuthRefusalAudit(");
    assert.ok(lastAudit > lastReturn, "queueAuthRefusalAudit( in the same branch as the -32001 reply");
  }
  assert.ok(n >= 1, "at least one -32001 reply");
  // No console.* call mentions the token, the verified token or the Authorization header.
  for (const c of SRC.match(/console\.[a-z]+\([^;]*\);/g) ?? []) {
    assert.equal(/verifiedToken|\.token\b|authorization/i.test(c), false, c);
  }
  // The refusal reply keeps the v5 message and status, adding only error.data.trace_id.
  assert.match(SRC, /error: \{ code: -32001, message: auth\.message, data: \{ trace_id: traceId \} \} \}, auth\.status, \{\n\s+"WWW-Authenticate": `Bearer realm="\$\{SERVER_NAME\}", resource_metadata="\$\{base\}\/\.well-known\/oauth-protected-resource"`,/);
  // v5 refusal texts, byte for byte.
  for (const msg of [
    `"Missing bearer token."`, `"Token failed verification."`, `"Token carries no subject."`,
    `"Token carries no client_id. This endpoint serves the registered connector only, not ordinary dashboard sessions."`,
    `"No active connection for this principal and client."`, `"This connection has expired."`,
  ]) assert.ok(SRC.includes(msg), msg);
});

const V5_TOOL_NAMES = [
  "list_family_projects", "list_work_items", "get_work_item", "create_work_item", "update_work_item",
  "list_work_item_comments", "add_work_item_comment", "list_labels", "set_work_item_labels",
  "list_family_records", "get_family_record", "create_family_record", "update_family_record",
  "list_care_audit_events", "list_family_agents", "get_family_agent_profile", "start_family_agent_session",
  "delegate_family_agent_session", "complete_family_agent_session", "list_my_family_agent_sessions",
  "assign_family_agent_to_work_item",
];

test("S-5 TOOLS: 21 tools with the v5 names in the v5 order; serverInfo 1.2.0", () => {
  const tools = SRC.slice(SRC.indexOf("const TOOLS = ["), SRC.indexOf("const ROLE_NOTICE"));
  const names = [...tools.matchAll(/\{ name: "([a-z_]+)"/g)].map((m) => m[1]);
  assert.equal(names.length, 21);
  assert.deepEqual(names, V5_TOOL_NAMES);
  assert.match(SRC, /const SERVER_VERSION = "1\.2\.0";/);
});
