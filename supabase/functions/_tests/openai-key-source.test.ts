// SB-503 guard: the three OpenAI-backed functions read the key from the
// server-side secret only, and fail closed when it is missing.
//
// Up to 2026-10-01 each resolved its key as
//     Deno.env.get("OPENAI_API_KEY") || body.openai_api_key
// on a verify_jwt=false endpoint. A caller-supplied key travels in a request
// body, and bodies reach logs; an unset secret also failed OPEN to whatever a
// caller sent instead of failing closed. These are source-level checks, because
// the fail-closed path cannot be exercised in production without unsetting the
// real secret. They run in CI through function-tests.yml, so a stray re-add of
// the fallback turns the build red.
//
// Run:  node --experimental-strip-types --test supabase/functions/_tests/openai-key-source.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const FUNCTIONS = join(dirname(fileURLToPath(import.meta.url)), "..");
const TARGETS = ["search-skills", "generate-skill-embeddings", "generate-memory-embeddings"];

function source(fn: string): string {
  return readFileSync(join(FUNCTIONS, fn, "index.ts"), "utf8");
}

for (const fn of TARGETS) {
  test(`${fn}: never reads an API key from the request body`, () => {
    const src = source(fn);
    assert.doesNotMatch(src, /body\s*(\?\.|\.)\s*openai_api_key/, "reads body.openai_api_key");
    assert.doesNotMatch(src, /body\s*\[\s*["']openai_api_key["']\s*\]/, "reads body['openai_api_key']");
    assert.doesNotMatch(src, /OPENAI_API_KEY"\)\s*(\|\||\?\?)/, "falls back after the env lookup");
  });

  test(`${fn}: reads the key from the server-side secret`, () => {
    assert.match(source(fn), /Deno\.env\.get\(\s*"OPENAI_API_KEY"\s*\)/);
  });

  test(`${fn}: fails closed with 500 when the secret is missing`, () => {
    const src = source(fn);
    // The guard on the missing key returns a 500, not a 4xx that reads like
    // the caller's fault and invites them to supply a key.
    const guard = src.match(/if\s*\(\s*!openaiKey\s*\)[\s\S]{0,400}?status:\s*(\d{3})/);
    assert.ok(guard, "no missing-key guard found");
    assert.equal(guard[1], "500");
  });

  test(`${fn}: no message invites a caller to pass a key`, () => {
    assert.doesNotMatch(source(fn), /pass openai_api_key/i);
  });
}
