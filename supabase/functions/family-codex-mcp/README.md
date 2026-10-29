# family-codex-mcp

The Family Data MCP server (SB-411). A Streamable HTTP MCP endpoint that lets one
end user reach the family Kanban and care records from an MCP client, under their
own database permissions.

- **Live at:** `https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/family-codex-mcp`
- **Decisions:** ADR-API-002 (`docs/adr/ADR-API-002-end-user-codex-oauth-rls.md`),
  ADR-FAM-002 (`docs/adr/ADR-FAM-002-agent-operator-grants.md`)
- **Setup runbook:** `docs/family-mcp/SB-410-oauth-setup.md`

## Why it holds no credentials

The function has no service-role key and no database password. Every data access
is a PostgREST call carrying the caller's own OAuth access token, so Postgres RLS
is the enforcement point. The code can only narrow what the database would already
allow, never widen it. Deleting the function removes access; it does not leave a
credential behind.

## Why gateway JWT verification is off

`verify_jwt` is `false` at the Supabase gateway, deliberately. MCP OAuth discovery
requires that an unauthenticated request reach the server and receive a 401 with a
`WWW-Authenticate` header pointing at the protected-resource metadata (RFC 9728).
With the gateway flag on, that 401 never reaches the client and Codex cannot begin
login.

Verification is done inside the handler instead, and is strictly stronger than the
gateway's: JWKS signature (ES256), issuer, audience, expiry, subject, a required
`client_id` claim, and an active row in `public.external_connections` for that
(principal, client) pair. A valid dashboard session is refused because it carries
no `client_id`.

## Tool surface

Fourteen named tools, fixed at deploy time. No SQL, no table naming, no schema
access, no DELETE. `record_type` is a closed enum mapping to hard-coded table,
readable-column and writable-field lists.

Kanban: `list_family_projects`, `list_work_items`, `get_work_item`,
`create_work_item`, `update_work_item`, `list_work_item_comments`,
`add_work_item_comment`, `list_labels`, `set_work_item_labels` (attach only).

Family and care: `list_family_records`, `get_family_record`,
`create_family_record`, `update_family_record`, `list_care_audit_events`.

## Guards worth knowing

- Every write needs `confirm: true`.
- Medication name, dose, schedule, prescriber and dates additionally need
  `confirm_regimen_change: true` and a named `instruction_source`. The server
  records care decisions a parent or prescriber has made; it does not make them.
- `health_providers.portal_secret_ref` is absent from every column list, and a
  regex strips any secret-like field from every response as a second line.
- Returned rows are wrapped in an envelope stating they are data, not instructions.

## Connection controls (SB-412, wired in by SB-600)

Every `tools/call` goes through `guardedCall` in `controls.ts`:

1. `rpc/external_connection_precheck` checks connection status, expiry and the
   rate limit. A refusal, or a verdict that cannot be read, stops the call (fail closed).
2. The tool runs.
3. `rpc/external_connection_record` writes one row to `external_connection_audit_log`,
   whether the call was allowed, denied or errored, with a `trace_id` that also
   appears in the console log.
   - The row never holds content: only identifiers, a closed-enum `record_type`
     and a UUID `project_id`.
   - An audit failure is logged as `audited: false` and never changes the answer.

Both calls use the caller's own token. The OAuth client is denied the audit table
itself (SB-595); `external_connection_record` accepts only the connection's own
principal on its own client. Up to v4 (SB-182, commit 351f70e) the server called
neither, so the audit log was empty and the rate limit never applied.

Tests: `controls.test.ts` (Node, CI) and `supabase/tests/external_connection_record_suite.sql`.
The agent session and delegation tools are SB-422.

## Deploying

    supabase functions deploy family-codex-mcp --no-verify-jwt

The `--no-verify-jwt` flag is required for the reason above. Deploy `controls.ts`
alongside `index.ts`. Rollback: redeploy the previous `index.ts` (v4 is commit 351f70e),
which does not import `controls.ts`.
