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

1. **Authentication → OAuth Server → Enable.** Set the *authorization path* to the consent page on
   the existing HTTPS app origin, e.g. `https://jasonkpaulsen.github.io/supabrain-kanban/oauth-consent.html`
   (adjust if the Pages origin differs). Leave **Dynamic Client Registration off**.
2. **Authentication → JWT → Signing keys:** use an asymmetric key (ES256 or RS256) so the Edge
   Function can verify tokens against the JWKS endpoint without a shared secret.
3. **OAuth Server → Clients → Register:** name `Mandy — Codex Family Data MCP (v1)`, type **public**
   (PKCE), redirect URI = the exact URL from Mandy. Copy the generated `client_id`.
4. Store it on the connection (SQL editor, as the owner):
   ```sql
   update public.external_connections
      set oauth_client_id = '<client_id from step 3>', status = 'active'
    where id = 'c0de0000-0000-4000-a000-000000000408';
   ```
   The `active` state is refused by a CHECK constraint until both `principal_user_id` and
   `oauth_client_id` are present (TC-SB408-V3).
5. Verify discovery: `https://hzqqvbvhnzmgqivfigej.supabase.co/.well-known/oauth-authorization-server`
   resolves and lists the authorization and token endpoints.
6. Site URL and every Redirect URL must be reachable HTTPS — no `localhost` in production.

## How the consent page behaves (already built)

- Requires a live Supabase login (Mandy's existing account; no dashboard/team account is created).
- Shows the client name, id and the redirect target from `getAuthorizationDetails`.
- Three explicit sections: core Kanban; **sensitive child health and care records**; **family
  agents**. Each has its own checkbox. *Allow* is enabled only when all three are ticked; *Deny*
  (or leaving any section unticked) calls `denyAuthorization` and shows a clear no-access state.
- Consent is never inferred from the email address or the parent relationship.
- No client secret or service-role key is present: the page uses only the public anon key that
  every dashboard page already ships.

## Acceptance still to run (blocked until steps 1–6 are done)

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
