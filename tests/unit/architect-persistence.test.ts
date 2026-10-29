// SB-618 guard: the Architect persistence constraint has one source of truth.
//
// The text lives in docs/skills/architect-architecture-persistence.md. The SB-618 migration
// wrote it into every active Architect's constraints, and supabase/tests/architect_persistence_suite.sql
// checks the live rows against its md5. If any of the three copies changes on its own, the
// live check and the doc disagree, so this fails until all three agree again.
//
// Run:  node --experimental-strip-types --test tests/unit/architect-persistence.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");

const doc = read("docs/skills/architect-architecture-persistence.md");
const m = doc.match(/<!-- BEGIN ARCHITECT PERSISTENCE CONSTRAINT -->\n([^\n]*)\n<!-- END ARCHITECT PERSISTENCE CONSTRAINT -->/);
const TEXT = m?.[1] ?? "";
const MD5 = createHash("md5").update(TEXT, "utf8").digest("hex");

test("the doc holds one line of constraint text with the expected prefix", () => {
  assert.ok(m, "constraint markers not found in the doc");
  assert.ok(TEXT.startsWith("ARCHITECTURE PERSISTENCE (SB-212, SB-618): "), "prefix changed; the suite matches on it");
  assert.equal(TEXT, TEXT.trim(), "no leading or trailing whitespace");
  assert.doesNotMatch(TEXT, /\$constraint\$/, "the text must not contain the migration's dollar-quote tag");
});

test("the newest migration that writes the constraint writes exactly the doc's text", () => {
  const files = readdirSync(join(ROOT, "supabase", "migrations")).filter((f) => f.endsWith(".sql")).sort()
    .filter((f) => read(`supabase/migrations/${f}`).includes("ARCHITECTURE PERSISTENCE (SB-212"));
  assert.ok(files.length >= 1, "no migration writes the constraint");
  const sql = read(`supabase/migrations/${files[files.length - 1]}`);
  const lit = sql.match(/\$constraint\$([\s\S]*?)\$constraint\$/);
  assert.ok(lit, "no $constraint$ literal in the migration");
  assert.equal(lit[1], TEXT);
  assert.ok(sql.includes(MD5), "the migration's assertion must use the doc text's md5");
});

test("the live check compares against the doc text's md5", () => {
  const suite = read("supabase/tests/architect_persistence_suite.sql");
  assert.match(suite, new RegExp(`canonical constant text := '${MD5}'`));
});
