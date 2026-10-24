// SB-627 guard: only the service role writes to project-assets.
//
// The 2026-03-28 policies gave PUBLIC (so anon too) INSERT, UPDATE and DELETE on project-assets,
// and every anonymous image upload ran paid image analysis. SB-627 moved uploads and updates to
// service_role and limited removal (and a new SELECT) to the caller's own image_assets files.
// This fails CI when a later migration hands a storage.objects policy back to PUBLIC or anon, or
// creates a project-assets write policy for a client role.
//
// Run:  node --experimental-strip-types --test tests/unit/project-assets-storage.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const SB627 = "20261024034014";
const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
const code = (f: string) => readFileSync(join(MIGRATIONS, f), "utf8").replace(/--[^\n]*/g, "");
const STORAGE_POLICY = /\b(?:create|alter)\s+policy\s+("[^"]+"|\w+)\s+on\s+storage\.objects\b[\s\S]*?;/gi;

test("the SB-627 migration moves writes to service_role and scopes removal to the owner", () => {
  const f = files.find((x) => x.startsWith(SB627));
  assert.ok(f, `migration ${SB627} not found`);
  const sql = code(f);
  assert.match(sql, /alter\s+policy\s+"Allow uploads"\s+on\s+storage\.objects\s+to\s+service_role\s*;/i);
  assert.match(sql, /alter\s+policy\s+"Allow updates"\s+on\s+storage\.objects\s+to\s+service_role\s*;/i);
  for (const name of ['"Allow deletes"', "project_assets_select_own"]) {
    const stmt = (sql.match(STORAGE_POLICY) ?? []).find((s) => s.includes(name));
    assert.ok(stmt, `${name} statement missing`);
    assert.match(stmt, /to\s+authenticated/i, `${name} must be for authenticated`);
    assert.match(stmt, /ia\.user_id\s*=\s*\(\s*select\s+auth\.uid\(\)\s*\)/i, `${name} must check the image_assets owner`);
  }
});

test("no later migration gives a storage.objects policy to PUBLIC or anon, or client writes", () => {
  const offenders: string[] = [];
  for (const f of files.filter((x) => x.slice(0, 14) > SB627)) {
    for (const s of code(f).match(STORAGE_POLICY) ?? []) {
      const flat = s.replace(/\s+/g, " ");
      if (/\bto\s+[^;]*\b(public|anon)\b/i.test(flat)) offenders.push(`${f}: ${flat.slice(0, 100)}`);
      // a policy with no TO clause applies to PUBLIC
      if (/^create\s+policy/i.test(flat) && !/\bto\s+\w/i.test(flat)) offenders.push(`${f}: ${flat.slice(0, 100)} (no TO: PUBLIC)`);
      if (/for\s+(insert|update|all)\b/i.test(flat) && /\bto\s+[^;]*\bauthenticated\b/i.test(flat)) offenders.push(`${f}: client write ${flat.slice(0, 80)}`);
    }
  }
  assert.deepEqual(offenders, [], "project-assets writes stay with service_role (SB-627)");
});
