// SB-817 guard: board search matches the ticket code.
//
// Jason, 2026-11-07: "where is sb-808, search won't pull it up when i search ticket
// number". The search haystack on each board left out ticket_code, so a ticket was
// found by its code only when the code happened to appear in its own text.
//
// Pins, at source level, on all three boards:
//   - the search haystack starts with the ticket code and keeps every field it had;
//   - the board loads kanban_board_view with select=*, which carries ticket_code
//     (the browser half is TC-SB817-1..3 in tests/e2e/board-search.spec.js);
//   - sw.js moved to jarvis-pwa-v15 or later, so installed apps fetch the new pages.
//
// Run:  node --experimental-strip-types --test tests/unit/board-search-ticket-code.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");

const HAYSTACK: Record<string, string> = {
  "jarvis-pwa.html": "hay=[it.ticket_code,it.title,it.description,it.project_name,it.agent_name].join(' ').toLowerCase()",
  "index.html": "hay=[it.ticket_code,it.title,it.description,it.project_name,it.agent_name].join(' ').toLowerCase()",
  "jarvis-dashboard.html": "var hay=[item.ticket_code,item.title,item.description,item.project_name,item.assignee,item.agent_name].concat(",
};

for (const [file, hay] of Object.entries(HAYSTACK)) {
  test(`${file}: search haystack includes ticket_code and keeps the existing fields`, () => {
    const src = read(file);
    assert.equal(src.split(hay).length - 1, 1, `expected exactly one search haystack in ${file}`);
    // No second, older haystack left behind without the code.
    assert.doesNotMatch(src, /hay=\[it(em)?\.title,/);
  });

  test(`${file}: board items come from kanban_board_view with select=* (carries ticket_code)`, () => {
    assert.match(read(file), /rest\/v1\/kanban_board_view\?select=\*/);
  });
}

test("sw.js CACHE_NAME is jarvis-pwa-v15 or later", () => {
  const m = read("sw.js").match(/const CACHE_NAME = 'jarvis-pwa-v(\d+)';/);
  assert.ok(m, "CACHE_NAME is jarvis-pwa-v<N>");
  assert.ok(Number(m![1]) >= 15, `CACHE_NAME is v${m![1]}, expected v15 or later`);
});
