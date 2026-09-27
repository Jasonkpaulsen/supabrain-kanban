# SB-413 — Connecting Mandy's Codex to the family data

The operator guide SB-413 asks for: how to connect, sign in, approve a write, see
what you have access to, revoke access, reconnect, and ask for more.

Ticket SB-413 · Epic SB-406 · ADR-API-002 · ADR-FAM-002 · Server SB-411 ·
Agent tools SB-422 · Connection `c0de0000-0000-4000-a000-000000000408`

## At a glance

| | |
|---|---|
| Server name in Codex | `family_data` |
| Server URL | `https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/family-codex-mcp` |
| OAuth client ID (public, not a secret) | `ab31fe36-418f-44fe-b822-a6ea2c39e74b` |
| Callback URL | `http://127.0.0.1:5555/callback/8Oa9VOcPQmPU` |
| Sign in as | `mpaulsen25@gmail.com` |
| Approval mode | `writes` — reads run freely, every change asks first |

There is no password, API key, token or client secret anywhere in this guide or in
the Codex configuration. The client is a public PKCE client; the only credential is
Mandy's own sign-in, and Codex stores the resulting tokens in the OS keyring when one is
available (otherwise in a file under `~/.codex`).

---

## Part 1 — One step for Jason first (Supabase dashboard, ~2 minutes)

**Add a second redirect URI to the OAuth client.** Without it, Mandy's sign-in fails
with a redirect-URI mismatch.

1. Supabase dashboard → project `hzqqvbvhnzmgqivfigej`.
2. **Authentication → OAuth Server → Clients** → `Mandy — Codex Family Data MCP (v1)`.
   (Not the organisation-level *OAuth Apps* page — that is for the Management API.)
3. Add this redirect URI, exactly:

   ```
   http://127.0.0.1:5555/callback/8Oa9VOcPQmPU
   ```

4. Keep the existing `http://127.0.0.1:5555/callback`. It is harmless and covers an
   older Codex.

### Why this is needed

The client was registered on 2026-09-08 with `http://127.0.0.1:5555/callback`, the
value Jason's Codex showed at the time. Codex has since added protection against
OAuth "mix-up" attacks (RFC 9700 §4.4). When an authorization server does not
advertise `authorization_response_iss_parameter_supported`, Codex appends a
server-specific ID to the callback path, so each server gets its own redirect:

- Supabase's metadata does **not** advertise it — checked live on 2026-09-27 at
  `/.well-known/oauth-authorization-server/auth/v1`.
- So Codex sends `…/callback/<id>`, where `<id>` is the first 9 bytes of
  SHA-256 over the full server URL, base64url-encoded: `8Oa9VOcPQmPU`.
- Supabase matches redirect URIs exactly, so the old registration alone fails.

Source: `codex-rs/rmcp-client/src/oauth_callback.rs` (`callback_mode`,
`callback_id_from_server_url`) and `perform_oauth_login.rs` (the pre-registered-client
branch), openai/codex at `985cf47`.

If Supabase later adds issuer support, Codex will send the shared callback instead —
which is why the old URI stays registered.

---

## Part 2 — On Mandy's computer

### 1. Check Codex is current

```bash
codex --version
```

Update Codex if it is more than a few weeks old. This guide was verified against the
Codex source of 2026-09-27.

### 2. Add the server to Codex's config

Open `~/.codex/config.toml` (create it if it does not exist) and add:

```toml
[mcp_servers.family_data]
url = "https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/family-codex-mcp"
auth = "oauth"

# Reads run without asking; anything that changes data asks first.
default_tools_approval_mode = "writes"

# The server's exact v1 tool list (SB-411 + SB-422). Nothing else is exposed.
enabled_tools = [
  # Kanban (read)
  "list_family_projects", "list_work_items", "get_work_item",
  "list_work_item_comments", "list_labels",
  # Kanban (write)
  "create_work_item", "update_work_item", "add_work_item_comment",
  "set_work_item_labels",
  # Family and care records (read)
  "list_family_records", "get_family_record", "list_care_audit_events",
  # Family and care records (write)
  "create_family_record", "update_family_record",
  # Family agents (read)
  "list_family_agents", "get_family_agent_profile", "list_my_family_agent_sessions",
  # Family agents (write)
  "start_family_agent_session", "delegate_family_agent_session",
  "complete_family_agent_session", "assign_family_agent_to_work_item",
]

[mcp_servers.family_data.oauth]
client_id = "ab31fe36-418f-44fe-b822-a6ea2c39e74b"
callback_url = "http://127.0.0.1:5555/callback/8Oa9VOcPQmPU"
callback_port = 5555

# SB-413: medication changes and agent-initiated writes prompt explicitly, even if
# someone later loosens default_tools_approval_mode above.
[mcp_servers.family_data.tools.create_family_record]
approval_mode = "prompt"

[mcp_servers.family_data.tools.update_family_record]
approval_mode = "prompt"

[mcp_servers.family_data.tools.start_family_agent_session]
approval_mode = "prompt"

[mcp_servers.family_data.tools.delegate_family_agent_session]
approval_mode = "prompt"

[mcp_servers.family_data.tools.assign_family_agent_to_work_item]
approval_mode = "prompt"
```

Do **not** add the official hosted Supabase MCP to this configuration. It is
platform access and stays internal (ADR-API-002).

### 3. Sign in

```bash
codex mcp login family_data
```

A browser opens.

1. Sign in as **`mpaulsen25@gmail.com`**.
2. The Paulsen family consent page appears. It has three sections, each with its own
   checkbox:
   - **Core Kanban**
   - **Sensitive child health and care records**
   - **Family agents**

   *Allow* only enables when all three are ticked. Leaving any unticked, or pressing
   *Deny*, grants nothing.
3. Press **Allow**, then return to the terminal — `codex mcp login` reports whether
   sign-in succeeded.

### 4. Restart Codex and check it connected

Quit and reopen Codex, then:

```bash
codex mcp list
codex mcp get family_data
```

`family_data` should be listed and enabled.

### 5. First test — read only

In a Codex conversation, ask:

> List my family projects.

Expected: seven projects — Holidays & Events, Household, Jai Peter Paulsen, Kai Cyril
Paulsen, Mandy Marie Paulsen, Paulsen Family, Travel Planning. No approval prompt,
because it is a read.

---

## Everyday use

### Reads

Anything that only looks — work items, comments, labels, school assignments, care
records, the audit trail, the list of family agents — runs without a prompt.

### Writes: Codex asks first

Every tool that changes data prompts before it runs: creating or updating a work
item, adding a comment, attaching a label, creating or updating a family record, and
starting, delegating, completing or assigning a family-agent session.

Read the prompt before approving. It shows the tool name and the exact values it
will write.

### Medication changes need a second confirmation

Changing a medication's name, dose, schedule, prescriber or dates needs more than an
approval. The server also requires:

- `confirm_regimen_change: true`
- `instruction_source` — who decided it, e.g. *"Dr Chen, visit 2026-09-02"* or
  *"parent decision"*

This server **records** decisions a parent or prescriber has already made. It never
makes or suggests them. Refill dates, pharmacy and adherence notes do not need the
second confirmation.

### Family agents

Ask *"Which family agents can I use?"* to see them. Starting a session adopts that
agent's role for the conversation — its instructions and guardrails. It does not
grant any extra access: everything still runs under Mandy's own permissions, and
nothing runs on its own.

### What this connection cannot do

- Delete anything. There is no delete tool. Labels can be attached but not removed.
- Run SQL, name a table, or see configuration.
- Reach any project Mandy is not a member of.
- See anyone else's agent sessions.

---

## See what you have access to

| Question | Ask Codex |
|---|---|
| Which projects can I reach? | *List my family projects.* |
| Which family agents can I use, and where? | *Which family agents can I use?* (`list_family_agents`) |
| What does one agent do? | *Show me the Family PM's role in the Paulsen Family project.* |
| What changed in the care records? | *Show the care audit log for Kai's project.* |
| Which agent sessions have I run? | *List my agent sessions.* |

The authoritative list of record types the connection can touch is in the database
(`public.external_connection_resource_grants`, connection `c0de…408`). As of
2026-09-27: activities, behavioral logs, care plans, family events, health events,
health providers, medications and school assignments (read and write); the care audit
log (read only); work items, comments and labels (read and write); projects and
project membership (read only). Jason can read it with the query in the appendix.

---

## Revoke access

There are two levels, and they mean different things.

### Sign out on this computer — Mandy can do this

```bash
codex mcp logout family_data
```

Deletes the stored tokens on this computer. The connection itself stays active, so
signing in again (Part 2, step 3) restores access.

### Cut off the connection entirely — Jason does this

Either of these stops every request on the next call, from any computer:

- Dashboard: **Authentication → OAuth Server → Grants** → revoke Mandy's grant; or
- SQL (Platform Engineer):

  ```sql
  update public.external_connections
     set status = 'revoked'
   where id = 'c0de0000-0000-4000-a000-000000000408';
  ```

The server checks for an **active** connection row on every request, and SB-409's
restrictive database policies refuse the rest.

### Revoke one category only

Ask the Platform Engineer to withdraw that category's grant in
`public.external_connection_resource_grants`, or a single agent's entry in
`public.agent_operator_grants`. These tables deliberately allow no delete from ordinary
sessions (SB-408), so this is a platform change behind Jason's approval. Everything
else keeps working.

---

## Reconnect

- **After a local sign-out:** run `codex mcp login family_data` again.
- **After Jason revoked it:** Jason sets the connection back to `active` (or re-grants in
  the dashboard), then Mandy runs `codex mcp login family_data`. The consent page
  appears again — consent is never assumed from a previous visit.
- **After changing computers:** repeat Part 2. Nothing is copied between machines.

## Ask for more access

Create a work item in the Paulsen Family project describing what you need and why —
you can ask Codex to do it: *"Create a work item asking Jason for access to X."*
Adding a record type or agent is a database change behind Jason's approval
(`production_change_requires_jason_approval` on every ticket in this epic); nothing on
Mandy's computer needs to change except, possibly, `enabled_tools` if a new tool is
added.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Browser shows a redirect-URI or *invalid redirect* error at sign-in | The `…/callback/8Oa9VOcPQmPU` URI is not registered | Part 1. If the error names a different redirect URI, register exactly that one — it means the server URL in `config.toml` differs from this guide |
| Sign-in fails immediately, "address already in use" | Something else is using port 5555 | Quit the other program, or ask Jason to register a different port and change `callback_port` and `callback_url` to match |
| `No active connection for this principal and client` | Connection revoked, or signed in with a different Google account | Check it was `mpaulsen25@gmail.com`; ask Jason whether the connection is active |
| `Token carries no client_id` | Signed in through the dashboard rather than through Codex | Run `codex mcp login family_data` |
| `That project is not one you are a member of` | Asked about a project outside the seven | Expected — ask for access |
| `regimen_confirmation_required` | A medication regimen change without the second confirmation | Say who decided it; Codex re-issues with `instruction_source` |
| Tools missing from the list | `enabled_tools` out of date, or a typo | Compare with the list in Part 2, step 2 |

---

## Acceptance (SB-413) — to be completed on Mandy's computer

| Check | How |
|---|---|
| Only `family_data` tools are exposed | `codex mcp list` shows no Supabase platform server |
| Reads work without platform access | Part 2, step 5 returns the seven projects |
| Writes require confirmation | Ask Codex to add a comment to a test work item; a prompt appears; approve |
| Revocation removes access | `codex mcp logout family_data`, then a read fails; sign back in and it works |
| Evidence | Screenshot of `codex mcp get family_data` and of the step 5 result, attached to SB-413 |

---

## Appendix — for Jason

Mandy's current grants:

```sql
select resource_name, operations
  from public.external_connection_resource_grants
 where connection_id = 'c0de0000-0000-4000-a000-000000000408'
 order by resource_name;
```

Connection state:

```sql
select status, oauth_client_id, expires_at
  from public.external_connections
 where id = 'c0de0000-0000-4000-a000-000000000408';
```

Re-deriving the callback ID if the server URL ever changes (Codex hashes the full URL
with SHA-256, keeps 9 bytes, base64url without padding):

```bash
python3 -c 'import hashlib,base64,sys;print(base64.urlsafe_b64encode(hashlib.sha256(sys.argv[1].encode()).digest()[:9]).decode().rstrip("="))' \
  "https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/family-codex-mcp"
```
