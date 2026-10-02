// SB-506 tests for path.ts. Imports the module that ships -- not a copy.
//
// Run:  node --experimental-strip-types --test supabase/functions/lce-image-ingest/path.test.ts
//
// Not deployed: only index.ts and path.ts are sent to the platform.

import { test } from "node:test";
import assert from "node:assert/strict";
import { checkPath, uploadTarget, PREFIX, MAX_PATH_LEN } from "./path.ts";

const BASE = "https://hzqqvbvhnzmgqivfigej.supabase.co";

// Every object in project-assets on 2026-09-23, verbatim from storage.objects.
// The compatibility corpus: if any of these stops validating, a real caller breaks.
const REAL_NAMES = [
  "test-image.png",
  "auto-test-architecture.png",
  "verify-pipeline-test.png",
  "lce-images/f09dfafa-0ddd-4e42-b3b1-c6318e5b6617/candidate-1.png",
  "lce-images/f09dfafa-0ddd-4e42-b3b1-c6318e5b6617/candidate-2.png",
  "lce-images/f09dfafa-0ddd-4e42-b3b1-c6318e5b6617/candidate-3.png",
  "lce-images/cc3dcfac-2f0b-4db0-ae88-895861affe6a/candidate-1.png",
  "lce-images/cc3dcfac-2f0b-4db0-ae88-895861affe6a/candidate-2.png",
  "lce-images/cc3dcfac-2f0b-4db0-ae88-895861affe6a/candidate-3.png",
  "lce-images/256a8013-8172-44b0-8d5a-c5d6af24fda6/candidate-3.png",
  "lce-images/d142e09b-41d6-41f8-addc-25f619fff3fa/candidate-1.png",
  "lce-images/d142e09b-41d6-41f8-addc-25f619fff3fa/candidate-2.png",
  "lce-images/d142e09b-41d6-41f8-addc-25f619fff3fa/candidate-3.png",
];

// The escapes recorded in SB-506, plus every neighbouring shape.
const ATTACKS: Array<[string, string]> = [
  ["../avatars/evil.png", "dot segment"],
  ["a/../../private/x.png", "dot segment"],
  ["../../storage/v1/object/other/x.png", "dot segment"],
  ["./x.png", "dot segment"],
  ["a/./b.png", "dot segment"],
  ["a/..", "dot segment"],
  ["..", "dot segment"],
  ["/x.png", "empty segment"],
  ["x/", "empty segment"],
  ["a//b.png", "empty segment"],
  ["a\\..\\b.png", "disallowed character"],
  ["..%2Favatars%2Fevil.png", "disallowed character"],
  ["%2e%2e/avatars/x.png", "disallowed character"],
  ["a.png?x=1", "disallowed character"],
  ["a#/../../x.png", "disallowed character"],
  ["a b.png", "disallowed character"],
  ["a\u0000.png", "disallowed character"],
  ["café.png", "disallowed character"],
  ["a/․․/b.png", "disallowed character"], // ONE DOT LEADER lookalikes
];

test("every real object name still validates and resolves to itself", () => {
  for (const name of REAL_NAMES) {
    const c = checkPath(name);
    assert.equal(c.ok, true, `real name rejected: ${name}`);
    const t = uploadTarget(BASE, name);
    assert.notEqual(t, null, `real name failed the invariant: ${name}`);
    assert.equal(new URL(t!).pathname, PREFIX + name);
    // Byte-identical to the URL v2 sent for the same input. This is what lets
    // the live verification skip uploading a real object to a PUBLIC bucket:
    // for every valid path, v3 calls storage with exactly the string v2 did,
    // and every line after the upload is unchanged from v2.
    assert.equal(t, `${BASE}/storage/v1/object/project-assets/${name}`);
  }
});

test("every recorded escape and neighbouring shape is refused, for the stated reason", () => {
  for (const [p, why] of ATTACKS) {
    const c = checkPath(p);
    assert.equal(c.ok, false, `accepted: ${JSON.stringify(p)}`);
    if (!c.ok) assert.ok(c.reason.includes(why), `${JSON.stringify(p)}: got "${c.reason}", want "${why}"`);
  }
});

test("empty and missing path keep the exact v2 response", () => {
  // SB-497's verification uses 400 "no path" as its "authenticated, stopped
  // before upload" signal. Changing this string would silently break that.
  assert.deepEqual(checkPath(null), { ok: false, reason: "no path" });
  assert.deepEqual(checkPath(""), { ok: false, reason: "no path" });
});

test("length boundary", () => {
  const atMax = "a".repeat(MAX_PATH_LEN - 4) + ".png";
  assert.equal(atMax.length, MAX_PATH_LEN);
  assert.equal(checkPath(atMax).ok, true);
  assert.equal(checkPath(atMax + "x").ok, false);
});

test("the cap is the documented 512, not merely 'whatever the constant says'", () => {
  // QA, SB-506: the test above derives its inputs FROM MAX_PATH_LEN, so it
  // proves the boundary is enforced wherever the constant sits -- and silently
  // follows it if someone raises it. Mutation M9 (512 -> 4096) survived it.
  // The commit, README and ticket all state 512; pin that number with
  // literals that do not come from the module under test.
  assert.equal(MAX_PATH_LEN, 512);
  assert.equal(checkPath("a".repeat(508) + ".png").ok, true);  // 512
  assert.equal(checkPath("a".repeat(509) + ".png").ok, false); // 513
});

test("'...' is an ordinary name, not traversal -- accepted and unrewritten", () => {
  // Only "." and ".." are special to URL parsing. Pinned so nobody "fixes"
  // the regex into refusing all dots and breaks real extensions.
  for (const p of ["...", "a/.../b.png", ".hidden.png", "x..png"]) {
    assert.equal(checkPath(p).ok, true, p);
    assert.notEqual(uploadTarget(BASE, p), null, p);
  }
});

test("the invariant stands on its own if the policy is bypassed", () => {
  // Layer independence: call uploadTarget directly with inputs checkPath would
  // refuse. If the allowlist is ever loosened, this is what still holds.
  for (const p of ["../avatars/evil.png", "a/../../private/x.png", "./x.png", "a.png?x=1", "a#frag"]) {
    assert.equal(uploadTarget(BASE, p), null, `invariant let through ${JSON.stringify(p)}`);
  }
});

test("non-vacuity: the pre-fix construction really did escape", () => {
  // Reproduces SB-506 against the v2 code path (no validation). If this ever
  // stops escaping, the tests above are no longer testing the real defect.
  const v2 = (p: string) => new URL(`${BASE}/storage/v1/object/project-assets/${p}`).pathname;
  assert.equal(v2("../avatars/evil.png"), "/storage/v1/object/avatars/evil.png");
  assert.equal(v2("a/../../private/x.png"), "/storage/v1/object/private/x.png");
  assert.ok(!v2("../x").startsWith(PREFIX));
});
