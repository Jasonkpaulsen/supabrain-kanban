// SB-091 guard: the dashboards' domain lists agree with the database.
//
// Each dashboard carries a hardcoded fallback domain list (used when no JARVIS
// briefing has loaded) and a domain -> colour map. When 'gambling' was renamed
// to 'prediction-markets' (migration 20260613152007) the colour maps gained the
// new key but the fallbacks kept 'gambling', a value projects_domain_check
// rejects, so a briefing-less load rendered a chip for a domain that cannot
// exist. This pins every list to the newest projects_domain_check in the
// migration history, so the next rename turns CI red instead of drifting.
//
// Run:  node --experimental-strip-types --test tests/unit/domain-taxonomy.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");
const DASHBOARDS = ["index.html", "jarvis-pwa.html", "jarvis-dashboard.html"];

// Domains whose project is archived. They stay valid in the database (their
// history must still render), but the morning briefing leaves them out of its
// live set, and the fallback mirrors the briefing. KEL was archived 2026-08-19.
const ARCHIVED_DOMAINS = new Set(["prediction-markets"]);

function quoted(list: string): string[] {
  return [...list.matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

// The allowed set from the newest migration that (re)defines the constraint.
// Filenames sort by their version prefix, so the last match wins.
function allowedDomains(): { file: string; domains: string[] } {
  let found: { file: string; domains: string[] } | null = null;
  for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
    const sql = readFileSync(join(MIGRATIONS, file), "utf8");
    const m = sql.match(/projects_domain_check\s+CHECK\s*\(\s*\(?\s*domain\s*=\s*ANY\s*\(\s*ARRAY\s*\[([^\]]+)\]/i);
    if (m) found = { file, domains: quoted(m[1]) };
  }
  assert.ok(found, "no migration defines projects_domain_check");
  return found;
}

function fallbackList(src: string): string[] {
  const m = src.match(/var\s+(?:DL_FALLBACK|DOMAIN_LIST_FALLBACK)\s*=\s*\[([^\]]*)\]/);
  assert.ok(m, "no fallback domain list found");
  return quoted(m[1]);
}

function colourKeys(src: string): string[] {
  const m = src.match(/var\s+(?:DC|DOMAIN_COLORS)\s*=\s*\{([^}]*)\}/);
  assert.ok(m, "no domain colour map found");
  return [...m[1].matchAll(/(?:'([^']+)'|([A-Za-z_][\w-]*))\s*:/g)].map((k) => k[1] ?? k[2]);
}

const { file: source, domains: ALLOWED } = allowedDomains();

test("the allowed set is read from the migration history", () => {
  // Sanity: if the regex silently matched nothing useful, every check below
  // would pass vacuously.
  assert.ok(ALLOWED.length >= 8, `only ${ALLOWED.length} domains parsed from ${source}`);
});

for (const page of DASHBOARDS) {
  const src = readFileSync(join(ROOT, page), "utf8");

  test(`${page}: fallback names only domains the database accepts`, () => {
    const bad = fallbackList(src).filter((d) => !ALLOWED.includes(d));
    assert.deepEqual(bad, [], `not allowed by ${source}: ${bad.join(", ")}`);
  });

  test(`${page}: fallback is the live set the briefing shows`, () => {
    const live = ALLOWED.filter((d) => !ARCHIVED_DOMAINS.has(d)).sort();
    assert.deepEqual([...fallbackList(src)].sort(), live);
  });

  test(`${page}: every domain has a colour and no colour is dead`, () => {
    const keys = colourKeys(src);
    const missing = ALLOWED.filter((d) => !keys.includes(d));
    const dead = keys.filter((k) => !ALLOWED.includes(k));
    assert.deepEqual({ missing, dead }, { missing: [], dead: [] });
  });
}
