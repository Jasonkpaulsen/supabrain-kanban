// SB-514 guard: the trigger functions client writes fire stay SECURITY DEFINER.
//
// SB-514 made trigger_memory_embedding, trigger_image_analysis and fn_trigger_skill_embedding
// SECURITY DEFINER with search_path '' and revoked EXECUTE from PUBLIC, anon and authenticated,
// so no client-executable function reaches pg_net. CREATE OR REPLACE FUNCTION resets both:
// a later migration that redefines one of them without SECURITY DEFINER would put the client
// back on its own pg_net privilege. This fails CI when that happens. The live rule (no
// client-executable function calls net.http_*) is checked by supabase/tests/pg_net_exposure_suite.sql.
//
// Run:  node --experimental-strip-types --test tests/unit/pg-net-client-path.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const SB514 = "20261023031556";
const FNS = ["trigger_memory_embedding", "trigger_image_analysis", "fn_trigger_skill_embedding"];
const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
const code = (f: string) => readFileSync(join(MIGRATIONS, f), "utf8").replace(/--[^\n]*/g, "");

test("the SB-514 migration makes all three definer and revokes EXECUTE", () => {
  const f = files.find((x) => x.startsWith(SB514));
  assert.ok(f, `migration ${SB514} not found`);
  const sql = code(f);
  for (const fn of FNS) {
    assert.match(sql, new RegExp(String.raw`alter\s+function\s+public\.${fn}\(\)\s+security\s+definer\s+set\s+search_path\s*=\s*''`, "i"), fn);
    assert.match(sql, new RegExp(String.raw`revoke\s+all\s+on\s+function[^;]*public\.${fn}\(\)[^;]*from\s+public,\s*anon,\s*authenticated`, "i"), fn);
  }
});

test("no later migration redefines them as SECURITY INVOKER", () => {
  const offenders: string[] = [];
  for (const f of files.filter((x) => x.slice(0, 14) > SB514)) {
    const sql = code(f);
    for (const fn of FNS) {
      const re = new RegExp(String.raw`create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?${fn}\s*\(\s*\)[\s\S]*?\bas\s+\$`, "gi");
      for (const head of sql.match(re) ?? []) {
        if (!/security\s+definer/i.test(head) || !/set\s+search_path\s+(?:to|=)\s*''/i.test(head)) offenders.push(`${f}: ${fn}`);
      }
      if (new RegExp(String.raw`alter\s+function\s+(?:public\.)?${fn}\s*\(\s*\)\s+security\s+invoker`, "i").test(sql)) offenders.push(`${f}: ${fn} (alter)`);
      if (new RegExp(String.raw`grant\s+(?:all|execute)[^;]*${fn}[^;]*\bto\b[^;]*\b(?:public|anon|authenticated)\b`, "i").test(sql)) offenders.push(`${f}: ${fn} (grant)`);
    }
  }
  assert.deepEqual(offenders, [], "keep these SECURITY DEFINER with search_path '' and no client EXECUTE");
});
