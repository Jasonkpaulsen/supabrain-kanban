// SB-623 guard: the project automation toggle and agent-runner agree on one flag.
//
// SB-390 moved agent-runner's gate from meta.dev_automation to projects.automation_status
// but left the board toggle (and its RPC) on the old meta key, so the toggle stopped doing
// anything and the board showed a state the runner ignored. This pins all three ends to
// automation_status: the runner's filter, the newest definition of the toggle RPC, and the
// three boards' read, fetch and write. If any of them drifts back to meta, CI goes red.
//
// Run:  node --experimental-strip-types --test tests/unit/project-automation-gate.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
// Comments may name the retired key; code may not.
const code = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

test("agent-runner gates on automation_status = 'active'", () => {
  const src = code(read("supabase/functions/agent-runner/index.ts"));
  assert.match(src, /from\("projects"\)\.select\("[^"]*\bautomation_status\b[^"]*"\)/);
  assert.match(src, /automation_status === "active"/);
  assert.doesNotMatch(src, /dev_automation(?!_config)/, "agent-runner must not read meta.dev_automation");
});

test("the newest set_project_dev_automation writes automation_status, not meta", () => {
  const defs = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()
    .filter((f) => /function\s+(public\.)?set_project_dev_automation\s*\(/i.test(readFileSync(join(MIGRATIONS, f), "utf8")));
  // Both the 2026-06 original (unqualified) and the SB-623 rewrite must be found, so a
  // later unqualified redefinition cannot slip past as "not the newest".
  assert.ok(defs.length >= 2, `expected the original and the SB-623 definition, found ${defs.join(", ")}`);
  const newest = defs[defs.length - 1];
  const sql = readFileSync(join(MIGRATIONS, newest), "utf8");
  const body = sql.slice(sql.search(/function\s+(public\.)?set_project_dev_automation/i));
  assert.match(body, /SET\s+automation_status\s*=/i, `${newest} must write automation_status`);
  assert.doesNotMatch(body, /\bmeta\s*=/i, `${newest} must not write meta`);
  assert.doesNotMatch(body.split(/\$function\$/)[0], /security\s+definer/i, `${newest} must stay SECURITY INVOKER`);
});

for (const [file, reader] of [
  ["index.html", "projDevAuto"], ["jarvis-pwa.html", "projDevAuto"], ["jarvis-dashboard.html", "projDevAutomation"],
] as const) {
  test(`${file} reads, fetches and writes automation_status`, () => {
    const src = code(read(file));
    assert.match(src, new RegExp(`function ${reader}\\(p\\)\\{\\s*return !!\\(p\\s*&&\\s*p\\.automation_status\\s*===\\s*'active'\\);\\s*\\}`));
    assert.match(src, /\/rest\/v1\/projects\?select=[^'&]*\bautomation_status\b/);
    assert.match(src, /p\.automation_status\s*=\s*body\.automation_status/);
    assert.doesNotMatch(src, /\.dev_automation\b(?!_config)/, `${file} must not touch meta.dev_automation`);
    assert.match(src, /if\s*\(\s*next\s*&&\s*!confirm\(/, `${file} must confirm before enabling`);
  });
}
