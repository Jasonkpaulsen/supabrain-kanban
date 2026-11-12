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

Twenty-one named tools (11 read, all `list_*`/`get_*`; 10 write), fixed at deploy
time. No SQL, no table naming, no schema access, no DELETE. `record_type` is a closed enum mapping to hard-coded table,
readable-column and writable-field lists.

Kanban: `list_family_projects`, `list_work_items`, `get_work_item`,
`create_work_item`, `update_work_item`, `list_work_item_comments`,
`add_work_item_comment`, `list_labels`, `set_work_item_labels` (attach only).

Family and care: `list_family_records`, `get_family_record`,
`create_family_record`, `update_family_record`, `list_care_audit_events`.

Family agent roles (SB-422): `list_family_agents`, `get_family_agent_profile`,
`start_family_agent_session`, `delegate_family_agent_session`,
`complete_family_agent_session`, `list_my_family_agent_sessions`,
`assign_family_agent_to_work_item`.

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

## Input limits (SB-825, v6)

Every writable field is checked in `validate.ts` before any database call; a value
over its cap is refused with `bad_request: <field> exceeds <max> characters.` (the
value is never echoed). Nothing is truncated silently. Lengths are Unicode code points.

| Field | Cap |
|---|---|
| work item / family event / school assignment `title` | 500 |
| work item and school assignment `description` | 20,000 |
| comment `body` | 10,000 |
| short record fields (names, types, statuses, locations, dose, schedule, ...) | 500 |
| `activity.contact_info` / `health_provider.portal_url` | 1,000 / 2,000 |
| long free-text record fields (notes, summaries, goals, ...) | 10,000 |
| date strings | 40 |
| `tags` | 50 items of 100 |
| `label_ids` | 1 to 20 |
| medication `instruction_source` | 500 |
| `purpose` / `result_summary` | 2,000 / 8,000 |
| whole JSON-RPC request | 256 KiB (HTTP 413) |

Work-item `status`, `priority` and `type` must be one of the schema enums. UUID and
boolean fields are type-checked. `list_family_projects`, `list_family_agents` and
`list_my_family_agent_sessions` take no paging arguments and are capped at 100 rows,
with `limit: 100` and `truncated` in the envelope. The paged tools were already
capped at 100 per page.

## Write rate limit (SB-826)

`external_connection_precheck` (migration `sb826_precheck_enforce_all_scopes`)
enforces every applicable limit row, not only the most specific one:

- aggregate (`tool_name` NULL): calls on this connection, 600 per hour;
- class (`tool_name = '*write*'`): write attempts by this principal on any
  connection, 120 per hour; rotating tools or reconnecting does not reset it;
- exact (`tool_name` = the tool): that tool on this connection, if a row exists.

A read tool is exactly `list_*`/`get_*`; anything else counts as a write.
`validate.test.ts` keeps that rule in step with `readOnlyHint`. Precheck refusals
(`rate_limited`) and identity-refusal rows (`auth`) do not count. Tool-level
denials such as `confirmation_required` do count, because they are write attempts.
A refused call answers `rate_limited: ... Retry after N s.`, with
`structuredContent: { error: "rate_limited", retry_after_seconds: N }` and an HTTP
`Retry-After: N` header. The window slides over 3,600 s.

## Identity-refusal audit (SB-827)

Every refused identity check (no token, malformed, bad signature, expired, wrong
issuer/audience, no subject, no `client_id`, unknown/other-principal/inactive/expired
connection, or a failed lookup) writes one row to `external_connection_audit_log` with
`operation = 'auth'` and a closed-set `reason_code`, through
`rpc/external_connection_record_auth_refusal` (migration `sb827_auth_refusal_audit`).

- Replies are unchanged from v5 (same status, message and `WWW-Authenticate`) plus
  `error.data.trace_id`, which matches the row's `trace_id` and the `auth_refused` log line.
- Before a token verifies, the call is anonymous (API key only) and the row has no
  connection, principal or client. After verification, the token rides only in the
  `Authorization` header, so the database derives the principal and client itself and
  re-derives the exact reason. The token is never stored, logged or sent in a body.
- Throttled in SQL: 10 rows per minute per principal (or for the shared anonymous
  bucket), 30 connection-less rows per minute overall, plus one
  `auth_refusals_throttled` marker per bucket. Each isolate also caps itself at 60
  audit calls per minute. Audit failures never change the reply.
- Expected noise: each fresh Codex connect makes one unauthenticated discovery POST,
  which leaves one `token_missing` row.
- The RPC is executable by `anon`. This is a deliberate, narrow exception to SB-443:
  it takes no connection id, returns nothing and stores no token.

DB fixtures for both: `supabase/tests/external_connection_limits_suite.sql` (rolled back,
raise-at-end; run after the migrations are applied).

## Deploying

    supabase functions deploy family-codex-mcp --no-verify-jwt

The `--no-verify-jwt` flag is required for the reason above. Deploy `controls.ts` and
`validate.ts` alongside `index.ts` (v6, serverInfo version `1.2.0`). Rollback: redeploy
v5 (`index.ts` md5 `26de43b12d78b042d90f32c5194bced6`, `controls.ts` md5
`9fa822377dff7d7c8947962f0531a740`, the files on `main` before SB-825), which does not
import `validate.ts` and works with both migrations in place. The precheck migration rolls
back by re-running its previous definition. The refusal-audit migration rolls back by
dropping `external_connection_record_auth_refusal(text, uuid)`. The nullable column and
CHECK constraint stay, because append-only rows cannot be removed.
