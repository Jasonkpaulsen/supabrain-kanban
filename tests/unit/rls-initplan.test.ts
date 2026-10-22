// SB-621 guard: RLS policies call auth.<fn>() once per statement, not once per row.
//
// SB-149 rewrote the policies of its day to (select auth.uid()); later migrations
// (20260802002910 on the Kalshi tables among them) went back to bare auth.uid(), and the
// performance advisor's auth_rls_initplan list grew to 20 before SB-621 fixed them. This
// fails CI when a migration after SB-621 creates or alters a policy with a bare call, so
// the next one is caught in review instead of by the advisor months later.
//
// Run:  node --experimental-strip-types --test tests/unit/rls-initplan.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const SB621 = "20261022132155";

// Policy statements in a migration, without SQL comments.
function policyStatements(sql: string): string[] {
  const code = sql.replace(/--[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
  return code.match(/\b(?:create|alter)\s+policy\b[\s\S]*?;/gi) ?? [];
}

// A call is fine when it is the whole of a scalar subquery: (select auth.uid()), in either
// the written form or the deparsed one, ( SELECT auth.uid() AS uid).
function bareCalls(stmt: string): string[] {
  const wrapped = /\(\s*select\s+auth\.(?:uid|jwt|role)\(\)(?:\s+as\s+\w+)?\s*\)/gi;
  return stmt.replace(wrapped, "").match(/\bauth\.(?:uid|jwt|role)\(\)/gi) ?? [];
}

test("the detector tells wrapped calls from bare ones", () => {
  assert.deepEqual(bareCalls("create policy p on t using ((select auth.uid()) = user_id);"), []);
  assert.deepEqual(bareCalls("alter policy p on t using ((user_id = ( SELECT auth.uid() AS uid)));"), []);
  assert.equal(bareCalls("create policy p on t using (auth.uid() = user_id);").length, 1);
  assert.equal(bareCalls("create policy p on t with check (exists (select 1 from c where c.o = auth.uid()));").length, 1);
  assert.equal(bareCalls("create policy p on t using ((auth.jwt() ->> 'role') = 'x');").length, 1);
  assert.equal(policyStatements("-- create policy x on t using (auth.uid() = u);\nselect 1;").length, 0);
});

test("the SB-621 migration itself leaves no bare call", () => {
  const file = readdirSync(MIGRATIONS).find((f) => f.startsWith(SB621));
  assert.ok(file, `migration ${SB621} not found`);
  const stmts = policyStatements(readFileSync(join(MIGRATIONS, file), "utf8"));
  assert.equal(stmts.length, 20, "expected the 20 ALTER POLICY statements");
  assert.deepEqual(stmts.filter((s) => bareCalls(s).length), []);
});

test("no migration after SB-621 adds a policy with a bare auth.<fn>() call", () => {
  const later = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql") && f.slice(0, 14) > SB621).sort();
  const offenders: string[] = [];
  for (const f of later) {
    for (const s of policyStatements(readFileSync(join(MIGRATIONS, f), "utf8"))) {
      if (bareCalls(s).length) offenders.push(`${f}: ${s.replace(/\s+/g, " ").slice(0, 120)}`);
    }
  }
  assert.deepEqual(offenders, [], "wrap auth.<fn>() as (select auth.<fn>()) in these policies");
});
