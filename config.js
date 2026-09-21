/* SB-182 — the one place this project's Supabase URL and publishable key live.
 *
 * Every page that talks to Supabase loads this file first. Rotating the key is
 * a one-line change here instead of a hunt through five HTML files, which is
 * the whole point of the ticket: before this, the key was pasted into
 * index.html, jarvis-pwa.html, jarvis-dashboard.html, oauth-consent.html and
 * article-studio/index.html, and rotating meant finding all five.
 *
 * THIS KEY IS MEANT TO BE PUBLIC. A publishable key identifies the app, not the
 * user — it is the modern replacement for the legacy `anon` JWT and Supabase
 * documents it as safe to ship in web pages, mobile binaries and source code.
 * What actually protects data is Row Level Security, audited under this ticket:
 * every table anon can reach has RLS enabled, every view is security_invoker,
 * and audit_client_role_exposure() reports zero findings. The key is the front
 * door's name plate, not its lock.
 *
 * NEVER put an `sb_secret_...` key or the `service_role` JWT in this file. Those
 * bypass RLS entirely. They belong in Vault or in Edge Function secrets, never
 * in anything a browser downloads.
 *
 * Writes always carry the signed-in user's session token in `Authorization`,
 * never this key. A publishable key is rejected outright in that header, so
 * sending it there does not merely weaken a request — it fails.
 */
window.SB_CONFIG = {
  url: 'https://hzqqvbvhnzmgqivfigej.supabase.co',
  key: 'sb_publishable_J-MA9d1UXLGwAZCLnSiSLg_cll_PQNv',
};
