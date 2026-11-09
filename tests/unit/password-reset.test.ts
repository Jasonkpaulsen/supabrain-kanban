// Password recovery guard (marker: sb-password-reset).
//
// A user could not reset a password: the app had no recovery handling at all, and a
// dashboard-sent reset landed on the bare Site URL, a 404 on GitHub Pages. Pins:
//   - the reset email's redirectTo is reset-password.html in the page's own folder
//     (so /supabrain-kanban/ on Pages), never a hard-coded host;
//   - a recovery or expired-link URL that lands on another page is forwarded to
//     reset-password.html with its hash and query intact;
//   - the "Back to the Codex approval" target is rebuilt from a validated
//     authorization_id, same origin and same folder only (no open redirect), and expires;
//   - every sign-in page loads password-reset.js before supabase-js and wires
//     "Forgot password?"; oauth-consent.html still needs a session and all three boxes;
//   - reset-password.html sets the password through updateUser only and handles the
//     expired-link error; sw.js precaches the module and moved past v15.
//
// Run:  node --experimental-strip-types --test tests/unit/password-reset.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
const PR = createRequire(import.meta.url)(join(ROOT, "password-reset.js"));

function loc(href: string) {
  const u = new URL(href);
  const replaced: string[] = [];
  return {
    href: u.href, origin: u.origin, pathname: u.pathname, search: u.search, hash: u.hash,
    replace: (to: string) => { replaced.push(to); }, replaced,
  };
}
const PAGES = "https://example.github.io/supabrain-kanban/";

test("resetUrl is reset-password.html next to the asking page", () => {
  assert.equal(PR.resetUrl(loc(PAGES + "oauth-consent.html?authorization_id=abc")), PAGES + "reset-password.html");
  assert.equal(PR.resetUrl(loc(PAGES)), PAGES + "reset-password.html");
  assert.equal(PR.resetUrl(loc("http://127.0.0.1:8099/index.html")), "http://127.0.0.1:8099/reset-password.html");
});

test("readUrl merges query and hash; expired and recovery links are recognised", () => {
  const p = PR.readUrl(loc(PAGES + "?x=1#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired"));
  assert.equal(p.x, "1");
  assert.equal(p.error_description, "Email link is invalid or has expired");
  assert.equal(PR.isRecoveryUrl(p), true);
  assert.equal(PR.isRecoveryUrl(PR.readUrl(loc(PAGES + "#access_token=t&type=recovery"))), true);
  assert.equal(PR.isRecoveryUrl(PR.readUrl(loc(PAGES + "index.html"))), false);
  assert.equal(PR.isRecoveryUrl(PR.readUrl(loc(PAGES + "#access_token=t&type=magiclink"))), false);
});

test("forwardRecovery moves a recovery link to reset-password.html, keeping hash and query", () => {
  const l = loc(PAGES + "#access_token=t&type=recovery");
  assert.equal(PR.forwardRecovery(l), true);
  assert.deepEqual(l.replaced, [PAGES + "reset-password.html#access_token=t&type=recovery"]);
  const here = loc(PAGES + "reset-password.html#access_token=t&type=recovery");
  assert.equal(PR.forwardRecovery(here), false, "never loops on the reset page itself");
  assert.equal(PR.forwardRecovery(loc(PAGES + "index.html")), false);
});

test("the consent return target is validated and rebuilt, never an open redirect", () => {
  const at = loc(PAGES + "reset-password.html");
  assert.equal(PR.consentTarget(PAGES + "oauth-consent.html?authorization_id=ab-12_x", at),
    PAGES + "oauth-consent.html?authorization_id=ab-12_x");
  assert.equal(PR.consentTarget(PAGES + "oauth-consent.html?authorization_id=a&next=https://evil.test", at),
    PAGES + "oauth-consent.html?authorization_id=a", "extra parameters are dropped");
  assert.equal(PR.consentTarget("https://evil.test/supabrain-kanban/oauth-consent.html?authorization_id=a", at), null);
  assert.equal(PR.consentTarget(PAGES + "index.html?authorization_id=a", at), null);
  assert.equal(PR.consentTarget("https://example.github.io/other/oauth-consent.html?authorization_id=a", at), null);
  assert.equal(PR.consentTarget(PAGES + "oauth-consent.html", at), null);
  assert.equal(PR.consentTarget(PAGES + "oauth-consent.html?authorization_id=%3Cscript%3E", at), null);
  assert.equal(PR.consentTarget("javascript:alert(1)", at), null);
});

test("remembered return expires and is absent when nothing was stored", () => {
  const mem = new Map<string, string>();
  const store = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => { mem.set(k, v); }, removeItem: (k: string) => { mem.delete(k); } };
  (globalThis as any).localStorage = store;
  try {
    const consent = loc(PAGES + "oauth-consent.html?authorization_id=abc");
    const at = loc(PAGES + "reset-password.html");
    assert.equal(PR.returnTarget(at, 1000), null);
    assert.equal(PR.rememberReturn(consent.href, consent, 1000), true);
    assert.equal(PR.returnTarget(at, 1000 + 60_000), PAGES + "oauth-consent.html?authorization_id=abc");
    assert.equal(PR.returnTarget(at, 1000 + PR.RETURN_TTL_MS + 1), null, "stale after the TTL");
    PR.forgetReturn();
    assert.equal(PR.returnTarget(at, 2000), null);
    assert.equal(PR.rememberReturn(PAGES + "index.html", consent, 1000), false, "only the consent page is stored");
  } finally {
    delete (globalThis as any).localStorage;
  }
});

test("send() asks Supabase for a reset whose redirectTo is the reset page", async () => {
  const calls: any[] = [];
  const client = { auth: { resetPasswordForEmail: async (e: string, o: any) => { calls.push([e, o]); return { data: {}, error: null }; } } };
  const r = await PR.send(client, "user@example.test", loc(PAGES + "index.html"));
  assert.equal(r.error, null);
  assert.deepEqual(calls, [["user@example.test", { redirectTo: PAGES + "reset-password.html" }]]);
  const boom = { auth: { resetPasswordForEmail: async () => { throw new Error("network down"); } } };
  assert.equal((await PR.send(boom, "a@b.c", loc(PAGES))).error.message, "network down");
});

test("every sign-in page loads password-reset.js before supabase-js and wires Forgot password", () => {
  const wiring: Record<string, RegExp> = {
    "index.html": /PasswordReset\.wireForgot\(\{client:sb,email:'l-email',after:'l-err'\}\)/,
    "jarvis-pwa.html": /PasswordReset\.wireForgot\(\{client:sb,email:'l-email',after:'l-err'\}\)/,
    "jarvis-dashboard.html": /PasswordReset\.wireForgot\(\{client:sb,email:'login-email',after:'login-error'\}\)/,
    "oauth-consent.html": /PasswordReset\.wireForgot\(\{ client: sb, email: 'l-email', after: 'l-err', rememberReturn: true \}\)/,
  };
  for (const [page, re] of Object.entries(wiring)) {
    const src = read(page);
    const mod = src.indexOf('<script src="password-reset.js"></script>');
    const lib = src.indexOf('<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>');
    assert.ok(mod > 0 && lib > mod, `${page}: password-reset.js loads before supabase-js`);
    assert.match(src, re, `${page}: Forgot password is wired to its sign-in form`);
  }
});

test("oauth-consent.html still needs a live session and all three explicit consents", () => {
  const src = read("oauth-consent.html");
  assert.match(src, /if \(!s\.data\.session\) \{ show\('login', true\); return; \}/);
  assert.match(src, /\$\('allow'\)\.disabled = !\(\$\('c-core'\)\.checked && \$\('c-medical'\)\.checked && \$\('c-agents'\)\.checked\)/);
  assert.match(src, /<button id="allow" disabled>/);
});

test("reset-password.html sets the password through updateUser and handles an expired link", () => {
  const src = read("reset-password.html");
  assert.match(src, /<script src="config\.js"><\/script>\s*<script src="password-reset\.js"><\/script>\s*<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2"><\/script>/);
  assert.match(src, /sb\.auth\.updateUser\(\{ password: p1 \}\)/);
  assert.match(src, /PASSWORD_RECOVERY/);
  assert.match(src, /link\.error \|\| link\.error_code \|\| link\.error_description/);
  assert.match(src, /verifyOtp\(\{ token_hash: link\.token_hash, type: 'recovery' \}\)/);
  assert.match(src, /if \(p1\.length < MIN\)/);
  assert.match(src, /if \(p1 !== p2\)/);
  assert.match(src, /PR\.returnTarget\(\)/, "the Codex link comes only from the validated stored target");
  assert.doesNotMatch(src, /sb_secret_|service_role/);
});

test("sw.js precaches password-reset.js and moved past jarvis-pwa-v15", () => {
  const src = read("sw.js");
  assert.match(src, /'\.\/password-reset\.js'/);
  const m = src.match(/const CACHE_NAME = 'jarvis-pwa-v(\d+)';/);
  assert.ok(m, "CACHE_NAME is jarvis-pwa-v<N>");
  assert.ok(Number(m![1]) >= 16, `CACHE_NAME is v${m![1]}, expected v16 or later`);
});
