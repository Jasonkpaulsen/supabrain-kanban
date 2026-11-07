// SB-803 (FU-BTN of SB-791) guard: the board's acceptance sign-off.
//
// Pins the client half of the L4 acceptance path:
//   - uat-signoff-ui.js signs off through rpc/signoff_test_case_uat only, and never
//     writes test_cases (the uat_* columns are the database's: trg_uat_guard);
//   - the button is offered only on a live case of a ticket in review that has no
//     current sign-off, and only to Jason's login (caseView mirrors the RPC's refusals);
//   - counts_for_l4 follows the gate's rule (live case, Jason Paulsen, signed at or
//     after review_entered_at);
//   - cancel-ui.js (loaded by exactly the three boards) loads the module, and each
//     board still has every global autoWire() reads, so the wiring cannot go silently dead;
//   - sw.js precaches it and its cache name moved past v13;
//   - PE N1 on SB-791: no board write sends review_entered_at.
//
// Run:  node --experimental-strip-types --test tests/unit/uat-signoff-button.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
// Comments may name what the code must not do; code may not.
const code = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
const UI = createRequire(import.meta.url)(join(ROOT, "uat-signoff-ui.js"));
const BOARDS = ["index.html", "jarvis-pwa.html", "jarvis-dashboard.html"] as const;

const REVIEW = { id: "t1", status: "review", archived: false, authority_level: 4, review_entered_at: "2026-11-06T20:00:00Z" };
const live = { id: "c1", status: "draft", archived: false, uat_signed_off_by: null, uat_signed_off_at: null };
const current = { ...live, id: "c2", uat_signed_off_by: "Jason Paulsen", uat_signed_off_at: "2026-11-06T21:00:00Z" };
const earlier = { ...live, id: "c3", uat_signed_off_by: "Jason Paulsen", uat_signed_off_at: "2026-11-06T19:00:00Z" };
const retired = { ...live, id: "c4", status: "retired" };
const archived = { ...live, id: "c5", archived: true };
const notJason = { ...live, id: "c6", uat_signed_off_by: "Jason", uat_signed_off_at: "2026-11-06T21:00:00Z" };

test("uat-signoff-ui.js calls rpc/signoff_test_case_uat and never writes test_cases", () => {
  const src = code(read("uat-signoff-ui.js"));
  assert.equal(UI.RPC, "signoff_test_case_uat");
  assert.match(src, /'\/rest\/v1\/rpc\/'\s*\+\s*RPC/);
  assert.match(src, /p_test_case_id:\s*caseId,\s*p_quote:\s*null,\s*p_notes:/, "the kanban channel call: case id, no quote, optional notes");
  assert.doesNotMatch(src, /method:\s*'(PATCH|PUT|DELETE)'/, "no PATCH, PUT or DELETE from the sign-off module");
  const posts = src.match(/method:\s*'POST'/g) || [];
  assert.equal(posts.length, 1, "exactly one POST: the RPC");
  assert.doesNotMatch(src, /p_recorded_by|p_said_at|attended:/, "the board never claims the attended channel");
  assert.match(src, /sb803-signoff/, "ticket marker present");
});

test("the database's refusal text is what the user sees (SB-776)", () => {
  const src = code(read("uat-signoff-ui.js"));
  assert.match(src, /b\.message \|\| b\.error_description \|\| b\.error \|\| b\.hint/);
  assert.match(src, /if \(!r\.ok\) throw new Error\(await dbMessage\(r\)\)/);
  assert.match(src, /err\.textContent = m/);
});

test("caseView offers Sign off only on a live, not-yet-current case of a review ticket, to Jason", () => {
  assert.equal(UI.caseView(live, REVIEW, true).canSign, true);
  assert.equal(UI.caseView(earlier, REVIEW, true).canSign, true, "a sign-off from before this review can be renewed");
  assert.equal(UI.caseView(notJason, REVIEW, true).canSign, true);
  for (const [name, tc] of [["current", current], ["retired", retired], ["archived", archived]] as const) {
    assert.equal(UI.caseView(tc, REVIEW, true).canSign, false, `${name} case must not offer Sign off`);
    assert.equal(UI.caseView(tc, REVIEW, true).state, name);
  }
  assert.equal(UI.caseView(live, REVIEW, false).canSign, false, "not Jason: no button");
  assert.equal(UI.caseView(live, { ...REVIEW, status: "in_progress" }, true).canSign, false, "ticket not in review");
  assert.equal(UI.caseView(live, { ...REVIEW, archived: true }, true).canSign, false, "archived ticket");
});

test("counts_for_l4 follows the L4 done gate's rule", () => {
  assert.equal(UI.countsForL4([live, earlier, notJason, retired], REVIEW), false);
  assert.equal(UI.countsForL4([live, current], REVIEW), true);
  assert.equal(UI.countsForL4([{ ...current, status: "retired" }], REVIEW), false, "retired cases do not count");
  assert.equal(UI.countsForL4([{ ...current, archived: true }], REVIEW), false, "archived cases do not count");
  assert.equal(UI.countsForL4([current], { ...REVIEW, review_entered_at: null }), false, "no review anchor, nothing counts");
  assert.equal(UI.countsForL4([current], { ...REVIEW, review_entered_at: "2026-11-06T22:00:00Z" }), false, "signed before the current review");
});

test("cancel-ui.js loads uat-signoff-ui.js once, and only the three boards load cancel-ui.js", () => {
  const src = code(read("cancel-ui.js"));
  assert.match(src, /querySelector\('script\[src\$="uat-signoff-ui\.js"\]'\)\) return;/);
  assert.match(src, /s\.src = 'uat-signoff-ui\.js';/);
  for (const other of ["oauth-consent.html", "article-studio/index.html"]) {
    assert.doesNotMatch(read(other), /cancel-ui\.js|uat-signoff-ui\.js/, `${other} must not load the sign-off module`);
  }
});

test("autoWire stands down on a board that wires the module itself, and wraps the three modal functions", () => {
  const src = code(read("uat-signoff-ui.js"));
  assert.match(src, /if \(!w\.document \|\| document\.getElementById\('m-uat'\)\) return false;/);
  for (const fn of ["openModal", "openNewModal", "closeModal"]) assert.match(src, new RegExp(`w\\.${fn} = function`));
  assert.match(src, /box\.setAttribute\('data-sb803', 'signoff'\)/);
});

for (const file of BOARDS) {
  test(`${file} loads cancel-ui.js and still has every global autoWire() reads`, () => {
    const src = read(file);
    assert.match(src, /<script src="cancel-ui\.js"><\/script>/);
    assert.match(src, /\n(async )?function openModal\(/);
    assert.match(src, /\nfunction openNewModal\(/);
    assert.match(src, /\nfunction closeModal\(\)/);
    assert.match(src, /\n(async )?function (hdr|getHeaders)\(/);
    assert.match(src, /\nfunction toast\(/);
    assert.match(src, /\nvar [^\n;]*\bisJason=false/);
    assert.match(src, /\nvar [^\n;]*\bedit(ing)?Item=null/);
    assert.match(src, /id="(cmt-s|comments-section)"/);
    assert.doesNotMatch(src, /<script type="module"/, "autoWire needs the board's globals on window");
    assert.doesNotMatch(code(src), /uat_signed_off|uat_batch_id|uat_notes/, `${file} must not touch uat_* itself`);
  });

  test(`${file}: no board write sends review_entered_at (PE N1 on SB-791)`, () => {
    assert.doesNotMatch(code(read(file)), /review_entered_at/);
  });
}

test("sw.js precaches uat-signoff-ui.js and moved past jarvis-pwa-v13", () => {
  const src = read("sw.js");
  assert.match(src, /'\.\/uat-signoff-ui\.js'/);
  assert.match(src, /const CACHE_NAME = 'jarvis-pwa-v14';/);
  assert.doesNotMatch(src, /'jarvis-pwa-v1[123]'/);
});
