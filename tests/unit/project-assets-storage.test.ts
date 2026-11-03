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

// Found by the SB-627 verifier: the owner rule trusts image_assets.storage_path, so clients must
// not create image_assets rows or move a row's path (20261024172958).
test("image_assets paths stay service-role only", () => {
  const f = files.find((x) => x.startsWith("20261024172958"));
  assert.ok(f, "the forged-path fix migration is missing");
  const sql = code(f);
  assert.match(sql, /create\s+trigger\s+trg_image_asset_path_service_only\s+before\s+insert\s+or\s+update\s+on\s+public\.image_assets/i);
  assert.match(sql, /current_user\s+in\s+\('anon',\s*'authenticated'\)/i);
  // SB-643 (2026-10-26) lets a signed-in user add a row for a file they already have a row for (a
  // header copy), and 20261026021942 refuses attaching a row to another user's article; the SB-627
  // suite re-ran with TC-SB643-02 (26 checks). Any other change trips this.
  const REVIEWED = ["20261026015944", "20261026021942"];
  const later = files.filter((x) => x.slice(0, 14) > "20261024172958")
    .filter((x) => /trg_image_asset_path_service_only|enforce_image_asset_path_service_only/i.test(code(x)));
  assert.deepEqual(later.map((x) => x.slice(0, 14)).filter((v) => !REVIEWED.includes(v)), [],
    "a later migration touches the image_assets path guard; re-run the SB-627 suite and update this test");
});

test("SB-643: the path guard allows only a copy of the caller's own row, on the caller's own article", () => {
  const f = files.find((x) => x.startsWith("20261026021942"));
  assert.ok(f, "the SB-643 migration is missing");
  const sql = code(f);
  const fn = sql.match(/create\s+or\s+replace\s+function\s+public\.enforce_image_asset_path_service_only\(\)[\s\S]*?\$function\$[\s\S]*?\$function\$/i)?.[0] ?? "";
  assert.ok(fn, "SB-643 redefines the path guard");
  assert.doesNotMatch(fn.split(/\$function\$/)[0], /security\s+definer/i, "the guard must stay invoker so its lookup runs under the caller's RLS");
  assert.match(fn, /current_user\s*=\s*'anon'\s+or\s+not\s+exists/i, "anon stays refused");
  assert.match(fn, /ia\.storage_bucket\s*=\s*new\.storage_bucket\s+and\s+ia\.storage_path\s*=\s*new\.storage_path/i);
  assert.match(fn, /ia\.user_id\s*=\s*\(select auth\.uid\(\)\)\s+and\s+new\.user_id\s*=\s*\(select auth\.uid\(\)\)/i);
  assert.match(fn, /new\.storage_path\s+is\s+distinct\s+from\s+old\.storage_path\s+or\s+new\.storage_bucket\s+is\s+distinct\s+from\s+old\.storage_bucket/i,
    "path and bucket changes stay service-role only");
  assert.match(fn, /new\.article_id\s+is\s+not\s+null\s+and\s+\(tg_op\s*=\s*'INSERT'\s+or\s+new\.article_id\s+is\s+distinct\s+from\s+old\.article_id\)/i);
  assert.match(fn, /a\.id\s*=\s*new\.article_id\s+and\s+a\.user_id\s*=\s*\(select auth\.uid\(\)\)/i, "only your own article");
});

// The path guard trusts current_user, so a SECURITY DEFINER function that writes image_assets
// would run as its owner and skip it. None exists (SB-627 verifier, 2026-10-24); keep it so.
test("no later migration adds a SECURITY DEFINER function that writes image_assets", () => {
  const FN = /create\s+(?:or\s+replace\s+)?function[\s\S]*?\$(\w*)\$[\s\S]*?\$\1\$/gi;
  const offenders: string[] = [];
  for (const f of files.filter((x) => x.slice(0, 14) > "20261024172958")) {
    for (const fn of code(f).match(FN) ?? []) {
      const head = fn.split(/\$\w*\$/)[0];
      if (/security\s+definer/i.test(head) && /\b(insert\s+into|update)\s+(public\.)?image_assets\b/i.test(fn)) {
        offenders.push(`${f}: ${head.replace(/\s+/g, " ").slice(0, 90)}`);
      }
    }
  }
  assert.deepEqual(offenders, [], "a definer function writing image_assets skips trg_image_asset_path_service_only");
});
