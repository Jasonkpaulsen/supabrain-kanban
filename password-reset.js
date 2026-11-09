/* Password recovery, shared by index.html, jarvis-pwa.html, jarvis-dashboard.html,
   oauth-consent.html and reset-password.html. Marker: sb-password-reset.

   Before this file the app had no recovery path at all: no "Forgot password?",
   no page for a recovery link to land on, no updateUser({ password }). A reset
   sent from the Supabase dashboard went to the project Site URL, and when that
   is the bare github.io root there is no page there, so the user got a 404.

   What it does:
   - resetUrl() is the explicit landing page, reset-password.html in the same
     folder as the page that asks, so the redirect target works on GitHub Pages
     (/supabrain-kanban/) and on a local server alike. Supabase only honours it
     when it matches an entry in Auth > URL Configuration > Redirect URLs;
     otherwise it falls back to the Site URL.
   - wireForgot() adds a "Forgot password?" button under a sign-in form. It
     uses the email already typed into that form and calls
     resetPasswordForEmail with redirectTo: resetUrl().
   - forwardRecovery() runs as soon as this file loads. A recovery link that
     lands on another page (a dashboard-sent reset goes to the Site URL, which
     is index.html) is moved to reset-password.html with its hash and query
     intact, before supabase-js reads them. Without it the board would sign the
     user in from the recovery token and never ask for a new password. Every
     page creates its client with the default implicit flow, so the hash is
     parsed locally and nothing is consumed twice.
   - rememberReturn() / returnTarget(): oauth-consent.html stores its own URL
     (only its authorization_id) before sending a link, so that after the new
     password is set, reset-password.html can offer "Back to the Codex
     approval". The value is rebuilt from a strictly validated authorization_id
     on read, same origin and same folder only, and is never an open redirect.
     It is kept in sessionStorage and, because the email link opens a NEW tab
     where sessionStorage is empty, also in localStorage with a two-hour expiry.
     The consent page itself is unchanged: it still needs a live session and
     the three explicit checkboxes. */
(function (root) {
  var RETURN_KEY = 'sb_reset_return';
  var RETURN_TTL_MS = 2 * 60 * 60 * 1000;
  var PAGE = 'reset-password.html';
  var CONSENT = 'oauth-consent.html';
  var AUTH_ID = /^[A-Za-z0-9._~-]{1,200}$/;
  var SENT = 'Check your email. The link works once and expires in about an hour. ' +
    'Open it directly from your email app, not from a message preview.';

  function folder(loc) { return loc.origin + loc.pathname.replace(/[^\/]*$/, ''); }
  function resetUrl(loc) { return folder(loc) + PAGE; }

  // Query and hash parameters together; Supabase puts errors and implicit-flow
  // tokens in the hash, and token_hash / code in the query.
  function readUrl(loc) {
    var out = {};
    [loc.search || '', (loc.hash || '').replace(/^#/, '')].forEach(function (part) {
      new URLSearchParams(part.replace(/^\?/, '')).forEach(function (v, k) { out[k] = v; });
    });
    return out;
  }

  function isRecoveryUrl(p) {
    return p.type === 'recovery' || p.error_code === 'otp_expired' ||
      /invalid or has expired/i.test(p.error_description || '');
  }

  function forwardRecovery(loc) {
    if (!loc || loc.pathname.slice(-PAGE.length) === PAGE) return false;
    if (!isRecoveryUrl(readUrl(loc))) return false;
    loc.replace(resetUrl(loc) + (loc.search || '') + (loc.hash || ''));
    return true;
  }

  function stores() {
    var s = [];
    try { if (root.sessionStorage) s.push(root.sessionStorage); } catch (e) { /* blocked */ }
    try { if (root.localStorage) s.push(root.localStorage); } catch (e) { /* blocked */ }
    return s;
  }

  // Only the consent page, only its authorization_id, rebuilt rather than reused.
  function consentTarget(href, loc) {
    var u;
    try { u = new URL(href, loc.href); } catch (e) { return null; }
    if (u.origin !== loc.origin) return null;
    if (u.pathname !== loc.pathname.replace(/[^\/]*$/, '') + CONSENT) return null;
    var id = u.searchParams.get('authorization_id');
    if (!id || !AUTH_ID.test(id)) return null;
    return folder(loc) + CONSENT + '?authorization_id=' + encodeURIComponent(id);
  }

  function rememberReturn(href, loc, now) {
    loc = loc || root.location;
    var t = consentTarget(href, loc);
    if (!t) return false;
    var v = JSON.stringify({ url: t, at: now || Date.now() });
    stores().forEach(function (s) { try { s.setItem(RETURN_KEY, v); } catch (e) { /* full or blocked */ } });
    return true;
  }

  function returnTarget(loc, now) {
    loc = loc || root.location;
    now = now || Date.now();
    var list = stores();
    for (var i = 0; i < list.length; i++) {
      var raw = null;
      try { raw = list[i].getItem(RETURN_KEY); } catch (e) { continue; }
      if (!raw) continue;
      var v;
      try { v = JSON.parse(raw); } catch (e) { continue; }
      if (!v || typeof v.url !== 'string' || !(now - Number(v.at) < RETURN_TTL_MS)) continue;
      var t = consentTarget(v.url, loc);
      if (t) return t;
    }
    return null;
  }

  function forgetReturn() {
    stores().forEach(function (s) { try { s.removeItem(RETURN_KEY); } catch (e) { /* blocked */ } });
  }

  async function send(client, email, loc) {
    try {
      return await client.auth.resetPasswordForEmail(email, { redirectTo: resetUrl(loc || root.location) });
    } catch (e) {
      return { error: { message: (e && e.message) || String(e) } };
    }
  }

  function wireForgot(o) {
    var doc = root.document;
    var email = doc.getElementById(o.email), after = doc.getElementById(o.after);
    if (!email || !after || doc.getElementById('pr-forgot')) return null;
    var box = doc.createElement('div');
    box.style.cssText = 'margin-top:12px;text-align:center;';
    var btn = doc.createElement('button');
    btn.type = 'button';
    btn.id = 'pr-forgot';
    btn.textContent = 'Forgot password?';
    btn.style.cssText = 'background:none;border:none;padding:4px;color:inherit;opacity:.8;' +
      'text-decoration:underline;font-size:14px;cursor:pointer;';
    var msg = doc.createElement('p');
    msg.id = 'pr-msg';
    msg.setAttribute('role', 'status');
    msg.setAttribute('aria-live', 'polite');
    msg.style.cssText = 'font-size:13px;margin:8px 0 0;line-height:1.4;';
    box.appendChild(btn);
    box.appendChild(msg);
    after.parentNode.insertBefore(box, after.nextSibling);
    function say(text, bad) { msg.textContent = text; msg.style.color = bad ? 'var(--red, #c0392b)' : ''; }
    btn.addEventListener('click', async function () {
      var addr = email.value.trim();
      if (!/^[^\s@]+@[^\s@]+$/.test(addr)) {
        say('Enter your email address above, then tap "Forgot password?" again.', true);
        email.focus();
        return;
      }
      if (o.rememberReturn) rememberReturn(root.location.href);
      btn.disabled = true;
      say('Sending…', false);
      var r = await send(o.client, addr);
      btn.disabled = false;
      if (r && r.error) say(r.error.message || 'Could not send the reset email.', true);
      else say(SENT, false);
    });
    return btn;
  }

  var api = {
    PAGE: PAGE,
    SENT: SENT,
    RETURN_KEY: RETURN_KEY,
    RETURN_TTL_MS: RETURN_TTL_MS,
    resetUrl: resetUrl,
    readUrl: readUrl,
    isRecoveryUrl: isRecoveryUrl,
    forwardRecovery: forwardRecovery,
    consentTarget: consentTarget,
    rememberReturn: rememberReturn,
    returnTarget: returnTarget,
    forgetReturn: forgetReturn,
    send: send,
    wireForgot: wireForgot,
  };
  root.PasswordReset = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  // Loaded in <head>, before supabase-js, so a recovery link moves on before
  // any client reads it.
  if (typeof document !== 'undefined' && root.location) forwardRecovery(root.location);
})(typeof window !== 'undefined' ? window : globalThis);
