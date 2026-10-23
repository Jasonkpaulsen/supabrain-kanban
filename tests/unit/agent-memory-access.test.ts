// SB-581 guard: users of an agent read its non-private memories (ADR-MEM-001).
//
// The SB-581 migration adds an agent path to memories.users_select_own and makes
// match_memories(p_agent) include global rows. This fails CI when a later migration redefines
// either and drops the private exclusion, the agent path or the global recall, or turns
// match_memories into SECURITY DEFINER (which would bypass RLS for every caller).
//
// Run:  node --experimental-strip-types --test tests/unit/agent-memory-access.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const SB581 = "20261023141914";
const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
const code = (f: string) => readFileSync(join(MIGRATIONS, f), "utf8").replace(/--[^\n]*/g, "");

const SELECT_POLICY = /\b(?:create|alter)\s+policy\s+"?users_select_own"?\s+on\s+(?:public\.)?memories\b[\s\S]*?;/gi;
const MATCH_FN = /create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?match_memories\s*\([\s\S]*?\$function\$[\s\S]*?\$function\$/gi;

test("the SB-581 migration is present", () => {
  assert.ok(files.some((f) => f.startsWith(SB581)), `migration ${SB581} not found`);
});

test("users_select_own keeps the agent path and the private exclusion", () => {
  const later = files.filter((f) => f.slice(0, 14) >= SB581);
  const stmts = later.flatMap((f) => (code(f).match(SELECT_POLICY) ?? []).map((s) => [f, s] as const));
  assert.ok(stmts.length >= 1, "expected the SB-581 ALTER POLICY");
  for (const [f, s] of stmts) {
    assert.match(s, /can_access_agent\s*\(\s*agent_id\s*,\s*\(\s*select\s+auth\.uid\(\)\s*\)\s*\)/i, `${f}: agent path missing`);
    assert.match(s, /agent_id\s+is\s+not\s+null\s+and\s+scope\s*<>\s*'private'\s+and\s+public\.can_access_agent/i,
      `${f}: the agent path must exclude private memories`);
  }
});

test("the newest match_memories recalls global rows for an agent and stays invoker", () => {
  const defs = files.flatMap((f) => (code(f).match(MATCH_FN) ?? []).map((s) => [f, s] as const));
  assert.ok(defs.length >= 1, "no match_memories definition found");
  const [f, def] = defs[defs.length - 1];
  assert.ok(f.slice(0, 14) >= SB581, `${f} predates SB-581`);
  assert.match(def, /p_agent\s+is\s+null\s+or\s+m\.agent_id\s*=\s*p_agent\s+or\s+m\.scope\s*=\s*'global'/i, `${f}: agent filter`);
  assert.doesNotMatch(def.split(/\$function\$/)[0], /security\s+definer/i, `${f}: match_memories must stay SECURITY INVOKER`);
  assert.match(def.split(/\$function\$/)[0], /set\s+search_path\s+to\s+''/i, `${f}: search_path must stay pinned`);
});
