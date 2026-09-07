# SB-410 — Supabase OAuth 2.1 + consent flow for Mandy's Codex

Status: **awaiting Jason** for the dashboard steps and one input from Mandy. The consent page
(`oauth-consent.html`) is built and deployed with the site; nothing below can be completed by an
agent because it needs the Supabase dashboard and the exact callback URL Codex displays.

Ticket SB-410 · Epic SB-406 · ADR-API-002 · Connection row `public.external_connections`
`c0de0000-0000-4000-a000-000000000408` (status `proposed`, `oauth_client_id` NULL until step 4).

## What Mandy supplies (one thing)

1. In Codex, add the MCP server (URL comes from SB-411 when the Edge Function exists; for the
   OAuth client registration only the **callback URL** matters).
2. Copy the **exact** redirect/callback URL Codex shows. Send it to Jason. No wildcard is used.

## What Jason does in the Supabase dashboard (project `hzqqvbvhnzmgqivfigej`)

None of these are reachable from the Supabase MCP toolset an agent has (database, Edge Functions,
advisors, docs, logs, branches) — Auth configuration has no tool surface there, so a human does them
in the console. Client registration *is* available through the auth admin API, but only with the
service-role key, which ADR-API-002 keeps off every non-platform surface; the dashboard is the
correct path.

1. **Authentication → URL Configuration.** Note the current **Site URL**. The authorization path in
   step 3 is *appended to Site URL* — it is a path, not a full URL. If Site URL is already the Pages
   origin (`https://jasonkpaulsen.github.io/supabrain-kanban`), nothing to change. If it is something
   else, changing it also changes where password-reset and magic-link emails send people for the
   existing dashboards, so check that before editing it.
2. **Authentication → Signing Keys:** migrate to an asymmetric key (ES256 or RS256). Default is HS256,
   which works for the code flow but cannot be validated by third parties against the JWKS endpoint,
   and ID tokens (the `openid` scope) fail outright under HS256.
3. **Authentication → OAuth Server → Enable**, then set **Authorization Path** to `/oauth-consent.html`
   (combined with Site URL this must resolve to the live consent page — merge PR #9 first and load the
   URL in a browser to confirm). Leave **dynamic client registration OFF**: it would let any MCP client
   register itself against this project.
4. **Authentication → OAuth Server → Clients → Register:** name `Mandy — Codex Family Data MCP (v1)`,
   client type **public** (token endpoint auth method `none`, PKCE), redirect URI = the exact URL from
   Mandy. Redirect URIs require an exact full-URL match — no wildcards, no partial paths. Copy the
   generated **Client ID**.
5. Hand the Client ID to the Platform Engineer, who writes it onto the connection row:
   ```sql
   update public.external_connections
      set oauth_client_id = '<client_id>', status = 'active'
    where id = 'c0de0000-0000-4000-a000-000000000408';
   ```
   The `active` state is refused by a CHECK constraint until both `principal_user_id` and
   `oauth_client_id` are present (TC-SB408-V3), so this write doubles as a test.

6. Verify discovery: `https://hzqqvbvhnzmgqivfigej.supabase.co/.well-known/oauth-authorization-server`
   resolves and lists the authorization and token endpoints.
7. Site URL and every Redirect URL must be reachable HTTPS — no `localhost` in production.

## How the consent page behaves (already built)

- Requires a live Supabase login (Mandy's existing account; no dashboard/team account is created).
- Shows the client name, id and the redirect target from `getAuthorizationDetails`.
- Three explicit sections: core Kanban; **sensitive child health and care records**; **family
  agents**. Each has its own checkbox. *Allow* is enabled only when all three are ticked; *Deny*
  (or leaving any section unticked) calls `denyAuthorization` and shows a clear no-access state.
- Consent is never inferred from the email address or the parent relationship.
- No client secret or service-role key is present: the page uses only the public anon key that
  every dashboard page already ships.

## Acceptance still to run (blocked until steps 1–7 are done)

| Case | What |
|---|---|
| TC-SB410-V2 | Discovery metadata resolves from the project issuer |
| TC-SB410-V3 | Authorization Code + PKCE succeeds from Mandy's Codex; token `sub` = her uid, `client_id` = the registered client |
| TC-SB410-V4 | Deny path yields no access; refresh, expiry, logout, revocation, re-authorization |
| TC-SB410-V5 | Token endpoint accepts any 2xx (HTTP 200 today) |
| TC-SB410-V6 | No client secret / service-role key in browser code, Codex config, logs or ticket comments |

Revocation: **Authentication → OAuth Server → Grants** (per user) or set the connection row to
`revoked`; SB-409's RESTRICTIVE guards make the next request fail. Re-authorization is the same
consent flow again.
