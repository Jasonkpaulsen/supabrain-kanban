// SB-825 / SB-826 / SB-827: pure checks in validate.ts, plus parity checks against the
// tool and resource definitions in index.ts (read as source: index.ts needs Deno).
// Run in CI by function-tests.yml:
//   node --experimental-strip-types --test supabase/functions/family-codex-mcp/validate.test.ts
// Synthetic strings only; no record content.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  AUTH_REASONS, authRefusalRequest, capRows, checkLabelIds, classifyJoseError, isReadToolName, LIMITS,
  RECORD_FIELD_SPECS, RefusalAuditGuard, textLen, ToolError, validateFields, WORK_ITEM_SPECS,
} from "./validate.ts";

const SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "index.ts"), "utf8");
const UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const TRACE = "99999999-8888-7777-6666-555555555555";
const x = (n: number) => "x".repeat(n);

function refused(fn: () => unknown, re?: RegExp) {
  assert.throws(fn, (e: unknown) => {
    assert.ok(e instanceof ToolError, "a ToolError");
    assert.equal((e as ToolError).code, "bad_request");
    if (re) assert.match((e as ToolError).message, re);
    return true;
  });
}

// ---------------------------------------------------------------- SB-825
test("U-825-1 textLen counts code points; boundaries", () => {
  assert.equal(textLen("abc"), 3);
  assert.equal(textLen("😀"), 1, "a surrogate pair is one character");
  assert.equal(textLen("a😀b"), 3);
  assert.equal(textLen("😀".repeat(500), 500), 500, "500 emoji are 1,000 UTF-16 units but 500 characters");
  assert.equal(textLen("😀".repeat(501), 500), 501);
  assert.equal(textLen(x(500), 500), 500);
  assert.equal(textLen(x(501), 500), 501);
  assert.equal(textLen(x(20_000), 20_000), 20_000);
  assert.equal(textLen(x(20_001), 20_000), 20_001);
});

test("U-825-2 work items: title 500, description 20,000, enums", () => {
  validateFields("work_items", { title: x(500) }, WORK_ITEM_SPECS);
  refused(() => validateFields("work_items", { title: x(501) }, WORK_ITEM_SPECS), /^title exceeds 500 characters\.$/);
  validateFields("work_items", { title: "😀".repeat(500) }, WORK_ITEM_SPECS);
  validateFields("work_items", { description: x(20_000) }, WORK_ITEM_SPECS);
  refused(() => validateFields("work_items", { description: x(20_001) }, WORK_ITEM_SPECS), /description exceeds 20000/);
  refused(() => validateFields("work_items", { title: x(600), description: x(25_000) }, WORK_ITEM_SPECS)); // N6a repro
  refused(() => validateFields("work_items", { description: x(25_000) }, WORK_ITEM_SPECS));
  for (const [f, good] of [["status", "in_progress"], ["priority", "high"], ["type", "bug"]] as const) {
    validateFields("work_items", { [f]: good }, WORK_ITEM_SPECS);
    refused(() => validateFields("work_items", { [f]: "urgent-ish" }, WORK_ITEM_SPECS), new RegExp(`^${f} must be one of: `));
    refused(() => validateFields("work_items", { [f]: 3 }, WORK_ITEM_SPECS));
  }
  validateFields("work_items", { due_date: "2026-11-30" }, WORK_ITEM_SPECS);
  refused(() => validateFields("work_items", { due_date: x(41) }, WORK_ITEM_SPECS));
  refused(() => validateFields("work_items", { title: ["a"] }, WORK_ITEM_SPECS), /^title must be a string\.$/);
  refused(() => validateFields("work_items", { assignee: "x" }, WORK_ITEM_SPECS), /not a writable field/);
  // Error messages never echo the value.
  try { validateFields("work_items", { title: "SENTINEL-" + x(600) }, WORK_ITEM_SPECS); } catch (e) {
    assert.equal((e as Error).message.includes("SENTINEL"), false);
  }
});

// One representative short (S) and long (L) field per record type.
const SHORT: Record<string, string> = {
  activity: "name", behavioral_log: "", care_plan: "plan_type", family_event: "event_type",
  health_event: "event_type", health_provider: "name", medication: "dose", school_assignment: "class_name",
};
const LONG: Record<string, string> = {
  activity: "", behavioral_log: "context", care_plan: "goals", family_event: "", health_event: "summary",
  health_provider: "notes", medication: "adherence_notes", school_assignment: "",
};

test("U-825-3 every record type: short/long caps, special caps, types, null", () => {
  for (const rt of Object.keys(RECORD_FIELD_SPECS)) {
    const specs = RECORD_FIELD_SPECS[rt];
    if (SHORT[rt]) {
      validateFields(rt, { [SHORT[rt]]: x(500) }, specs);
      refused(() => validateFields(rt, { [SHORT[rt]]: x(501) }, specs), /exceeds 500 characters/);
    }
    if (LONG[rt]) {
      validateFields(rt, { [LONG[rt]]: x(10_000) }, specs);
      refused(() => validateFields(rt, { [LONG[rt]]: x(10_001) }, specs), /exceeds 10000 characters/);
    }
    // Arrays and objects in every text field are refused; null clears and is allowed.
    for (const [f, s] of Object.entries(specs)) {
      validateFields(rt, { [f]: null }, specs);
      if (s.kind === "text" || s.kind === "date") {
        refused(() => validateFields(rt, { [f]: ["a"] }, specs), /must be a string/);
        refused(() => validateFields(rt, { [f]: { a: 1 } }, specs), /must be a string/);
        refused(() => validateFields(rt, { [f]: 7 }, specs), /must be a string/);
      }
      if (s.kind === "date") refused(() => validateFields(rt, { [f]: x(41) }, specs), /exceeds 40/);
      if (s.kind === "uuid") {
        validateFields(rt, { [f]: UUID }, specs);
        refused(() => validateFields(rt, { [f]: "not-a-uuid" }, specs), new RegExp(`^${f} must be a UUID\\.$`));
      }
      if (s.kind === "bool") {
        validateFields(rt, { [f]: false }, specs);
        refused(() => validateFields(rt, { [f]: "true" }, specs), new RegExp(`^${f} must be a boolean\\.$`));
      }
    }
  }
  const fe = RECORD_FIELD_SPECS.family_event;
  validateFields("family_event", { title: x(500) }, fe);
  refused(() => validateFields("family_event", { title: x(501) }, fe));
  const sa = RECORD_FIELD_SPECS.school_assignment;
  validateFields("school_assignment", { title: x(500), description: x(20_000) }, sa);
  refused(() => validateFields("school_assignment", { description: x(20_001) }, sa), /description exceeds 20000/);
  refused(() => validateFields("school_assignment", { title: x(501) }, sa));
  const ac = RECORD_FIELD_SPECS.activity;
  validateFields("activity", { contact_info: x(1_000) }, ac);
  refused(() => validateFields("activity", { contact_info: x(1_001) }, ac), /exceeds 1000/);
  const hp = RECORD_FIELD_SPECS.health_provider;
  validateFields("health_provider", { portal_url: x(2_000) }, hp);
  refused(() => validateFields("health_provider", { portal_url: x(2_001) }, hp), /exceeds 2000/);
  const bl = RECORD_FIELD_SPECS.behavioral_log;
  validateFields("behavioral_log", { tags: Array.from({ length: 50 }, () => x(100)) }, bl);
  validateFields("behavioral_log", { tags: [] }, bl);
  refused(() => validateFields("behavioral_log", { tags: Array.from({ length: 51 }, () => "t") }, bl), /^tags may hold at most 50 items of at most 100 characters\.$/);
  refused(() => validateFields("behavioral_log", { tags: [x(101)] }, bl), /tags may hold/);
  refused(() => validateFields("behavioral_log", { tags: "a,b" }, bl), /tags may hold/);
  refused(() => validateFields("behavioral_log", { tags: [1] }, bl), /tags may hold/);
  refused(() => validateFields("unknown_type", { a: "b" }, RECORD_FIELD_SPECS.unknown_type));
});

// Parse RESOURCES from index.ts: each `  <type>: {` block with its create/update lists.
function parseResources(src: string): Record<string, { create: string[]; update: string[] }> {
  const start = src.indexOf("const RESOURCES");
  const end = src.indexOf("const WORK_ITEM_READ");
  const block = src.slice(start, end);
  const out: Record<string, { create: string[]; update: string[] }> = {};
  const parts = block.split(/\n  (?=[a-z_]+: \{)/).slice(1);
  const list = (part: string, key: string) => {
    const m = part.match(new RegExp(`\\b${key}: \\[([^\\]]*)\\]`));
    assert.ok(m, `${key} list`);
    return [...m[1].matchAll(/"([a-z_]+)"/g)].map((g) => g[1]);
  };
  for (const part of parts) {
    const name = part.match(/^([a-z_]+): \{/)![1];
    out[name] = { create: list(part, "create"), update: list(part, "update") };
  }
  return out;
}

test("U-825-4 drift guard: RESOURCES writable fields and RECORD_FIELD_SPECS match exactly", () => {
  const res = parseResources(SRC);
  assert.deepEqual(Object.keys(res).sort(), Object.keys(RECORD_FIELD_SPECS).sort());
  for (const [rt, def] of Object.entries(res)) {
    const writable = new Set([...def.create, ...def.update]);
    const specd = new Set(Object.keys(RECORD_FIELD_SPECS[rt]));
    for (const f of writable) assert.ok(specd.has(f), `${rt}.${f} has a spec`);
    for (const f of specd) assert.ok(writable.has(f), `${rt}.${f} spec names a writable field`);
  }
  const wl = (k: string) => [...SRC.match(new RegExp(`const ${k} = \\[([^\\]]*)\\]`))![1].matchAll(/"([a-z_]+)"/g)].map((g) => g[1]);
  const wiWritable = new Set([...wl("WORK_ITEM_CREATE"), ...wl("WORK_ITEM_UPDATE")]);
  assert.deepEqual([...wiWritable].sort(), Object.keys(WORK_ITEM_SPECS).sort(), "work-item writable fields == WORK_ITEM_SPECS");
});

test("U-825-5 capRows", () => {
  for (const n of [0, 99, 100, 101, 5_000]) {
    const r = capRows(Array.from({ length: n }, (_, i) => i), 100);
    assert.equal(r.rows.length, Math.min(n, 100));
    assert.equal(r.truncated, n > 100);
  }
  assert.deepEqual(capRows(null, 100), { rows: [], truncated: false });
  assert.equal(LIMITS.LIST_CAP, 100);
  // list_family_agents pair fetch (cap + 1 rows requested): exactly 1,000 pairs is not truncation.
  for (const n of [999, 1_000, 1_001]) {
    const r = capRows(Array.from({ length: n }, (_, i) => i), LIMITS.AGENT_PAIRS_FETCH);
    assert.equal(r.rows.length, Math.min(n, 1_000));
    assert.equal(r.truncated, n > 1_000, `pairs ${n}`);
  }
});

test("U-825-6 label_ids 0 / 1 / 20 / 21", () => {
  refused(() => checkLabelIds([]), /^label_ids must hold 1 to 20 ids\.$/);
  assert.equal(checkLabelIds([UUID]).length, 1);
  assert.equal(checkLabelIds(Array.from({ length: 20 }, () => UUID)).length, 20);
  refused(() => checkLabelIds(Array.from({ length: 21 }, () => UUID)));
  refused(() => checkLabelIds("x"));
  refused(() => checkLabelIds(undefined));
});

// ---------------------------------------------------------------- SB-826
test("U-826-1 isReadToolName matches readOnlyHint for every tool; 11 reads, 10 writes, 21 tools", () => {
  const tools = [...SRC.matchAll(/\{ name: "([a-z_]+)", title: "[^"]*", annotations: (READ_ONLY|WRITE)\b/g)]
    .map((m) => ({ name: m[1], read: m[2] === "READ_ONLY" }));
  assert.equal(tools.length, 21);
  for (const t of tools) assert.equal(isReadToolName(t.name), t.read, t.name);
  assert.equal(tools.filter((t) => t.read).length, 11);
  assert.equal(tools.filter((t) => !t.read).length, 10);
  assert.match(SRC, /const READ_ONLY = \{ readOnlyHint: true,/);
  assert.match(SRC, /const WRITE = \{ readOnlyHint: false,/);
  assert.equal(isReadToolName("unknown_tool"), false);
  assert.equal(isReadToolName("list_"), false);
  assert.equal(isReadToolName("get_X"), false);
});

// ---------------------------------------------------------------- SB-827
const jose = (code: string, claim?: string) => Object.assign(new Error("m"), { code, ...(claim ? { claim } : {}) });

test("U-827-1 classifyJoseError", () => {
  assert.equal(classifyJoseError(jose("ERR_JWS_INVALID")), "token_malformed");
  assert.equal(classifyJoseError(jose("ERR_JWT_INVALID")), "token_malformed");
  for (const c of ["ERR_JWS_SIGNATURE_VERIFICATION_FAILED", "ERR_JWKS_NO_MATCHING_KEY", "ERR_JWKS_MULTIPLE_MATCHING_KEYS",
    "ERR_JOSE_ALG_NOT_ALLOWED", "ERR_JOSE_NOT_SUPPORTED"]) assert.equal(classifyJoseError(jose(c)), "token_bad_signature", c);
  assert.equal(classifyJoseError(jose("ERR_JWT_EXPIRED", "exp")), "token_expired");
  assert.equal(classifyJoseError(jose("ERR_JWT_CLAIM_VALIDATION_FAILED", "aud")), "token_wrong_audience");
  assert.equal(classifyJoseError(jose("ERR_JWT_CLAIM_VALIDATION_FAILED", "iss")), "token_wrong_issuer");
  assert.equal(classifyJoseError(jose("ERR_JWT_CLAIM_VALIDATION_FAILED", "nbf")), "token_not_yet_valid");
  assert.equal(classifyJoseError(jose("ERR_JWT_CLAIM_VALIDATION_FAILED", "iat")), "token_invalid");
  assert.equal(classifyJoseError(jose("ERR_JWKS_TIMEOUT")), "identity_check_error");
  assert.equal(classifyJoseError(jose("ERR_JWKS_INVALID")), "identity_check_error");
  assert.equal(classifyJoseError(jose("ERR_JWT_SOMETHING_NEW")), "token_invalid");   // unknown jose code: the token's
  assert.equal(classifyJoseError(jose("ERR_JWE_INVALID")), "token_invalid");
});

test("U-827-1b classifyJoseError: JWKS fetch failures and non-jose throws are ours (identity_check_error)", () => {
  // jose 5 fetch_jwks: non-200 response and unparseable body throw a generic JOSEError.
  assert.equal(classifyJoseError(jose("ERR_JOSE_GENERIC")), "identity_check_error");
  // Plain network failures surface as the runtime's own fetch error, without a jose code.
  assert.equal(classifyJoseError(new TypeError("fetch failed")), "identity_check_error");
  assert.equal(classifyJoseError(Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNREFUSED" } })), "identity_check_error");
  assert.equal(classifyJoseError(Object.assign(new Error("connection refused"), { code: "ECONNREFUSED" })), "identity_check_error");
  assert.equal(classifyJoseError(new DOMException("aborted", "AbortError")), "identity_check_error");
  assert.equal(classifyJoseError(jose("ERR_SOMETHING_NEW")), "identity_check_error");
  assert.equal(classifyJoseError({}), "identity_check_error");
  assert.equal(classifyJoseError({ code: 5 }), "identity_check_error");
  assert.equal(classifyJoseError("boom"), "identity_check_error");
  assert.equal(classifyJoseError(null), "identity_check_error");
  assert.equal(classifyJoseError(undefined), "identity_check_error");
});

test("U-827-2 authRefusalRequest: anon has no Authorization; body is two keys and never the token", () => {
  const SENTINEL = "eyJTOKEN-SENTINEL.payload.sig";
  const anon = authRefusalRequest("token_missing", null, TRACE, "api-key");
  assert.equal("Authorization" in anon.headers, false);
  assert.equal(anon.headers.apikey, "api-key");
  assert.deepEqual(Object.keys(anon.body).sort(), ["p_reason_code", "p_trace_id"]);
  assert.deepEqual(anon.body, { p_reason_code: "token_missing", p_trace_id: TRACE });

  const ver = authRefusalRequest("client_id_missing", SENTINEL, TRACE, "api-key");
  assert.equal(ver.headers.Authorization, `Bearer ${SENTINEL}`);
  assert.deepEqual(Object.keys(ver.body).sort(), ["p_reason_code", "p_trace_id"]);
  assert.equal(JSON.stringify(ver.body).includes("SENTINEL"), false);
  assert.equal(authRefusalRequest("token_invalid", null, "not-a-uuid", "k").body.p_trace_id, null);
});

test("U-827-3 RefusalAuditGuard: 60 per window, then refused, then allowed again", () => {
  let t = 1_000_000;
  const g = new RefusalAuditGuard(60, 60_000, () => t);
  for (let i = 0; i < 60; i++) assert.equal(g.allow(), true, `call ${i + 1}`);
  assert.equal(g.allow(), false, "61st refused");
  t += 59_999;
  assert.equal(g.allow(), false, "still inside the window");
  t += 1;
  assert.equal(g.allow(), true, "window has passed");
});

// Duplicated on purpose from supabase/migrations/*_sb827_auth_refusal_audit.sql
// (k_token || k_identity in external_connection_record_auth_refusal). Change both together.
const SQL_K_TOKEN = ["token_missing", "token_malformed", "token_bad_signature", "token_expired",
  "token_not_yet_valid", "token_wrong_issuer", "token_wrong_audience",
  "token_invalid", "token_no_subject", "identity_check_error"];
const SQL_K_IDENTITY = ["client_id_missing", "connection_not_found", "connection_principal_mismatch",
  "connection_proposed", "connection_disabled", "connection_revoked", "connection_expired"];

test("U-827-4 AUTH_REASONS are identifiers and equal the SQL arrays", () => {
  for (const r of AUTH_REASONS) assert.match(r, /^[a-z_]{1,64}$/);
  assert.deepEqual([...AUTH_REASONS], [...SQL_K_TOKEN, ...SQL_K_IDENTITY]);
  assert.equal((AUTH_REASONS as readonly string[]).includes("auth_refusals_throttled"), false);
  // and the migration file in the repo says the same
  const migDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "migrations");
  const files = (readdirSafe(migDir)).filter((f) => f.endsWith("_sb827_auth_refusal_audit.sql"));
  assert.equal(files.length, 1, "exactly one sb827 migration file");
  const sql = readFileSync(join(migDir, files[0]), "utf8");
  const arr = (name: string) => [...sql.match(new RegExp(`${name}\\s+constant text\\[\\] := array\\[([^\\]]*)\\]`))![1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
  assert.deepEqual(arr("k_token"), SQL_K_TOKEN);
  assert.deepEqual(arr("k_identity"), SQL_K_IDENTITY);
});

function readdirSafe(d: string): string[] { try { return readdirSync(d); } catch { return []; } }
