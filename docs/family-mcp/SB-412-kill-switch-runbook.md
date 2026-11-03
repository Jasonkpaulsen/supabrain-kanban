# Killing and restoring Mandy's family connection

**SB-412.** One screen. Read this when you need to cut access now and work out why later.

There are no secrets in this document. It is safe to keep open, print, or paste into a chat.

---

## Cut access now

Open the Supabase SQL editor for project `hzqqvbvhnzmgqivfigej` and run:

```sql
select * from set_external_connection_status(
  'c0de0000-0000-4000-a000-000000000408',
  'disabled',
  'why you are doing this'
);
```

That is the whole kill switch. It takes effect on the **next call** — measured at 16 ms in
testing, with no cache and no deploy — and it writes its own audit row, so the reason you
typed is on the record.

`disabled` is the one to use when you are unsure. It is reversible in one command.

### If you believe the token itself is compromised

`disabled` stops the connection. It does **not** invalidate an OAuth token that has already
been issued. For that, also revoke the grant in the dashboard:

**Authentication → OAuth Server → Clients →** the client `ab31fe36-418f-44fe-b822-a6ea2c39e74b`
**→ revoke.**

Use `'revoked'` rather than `'disabled'` in the SQL above so the audit trail says which of the
two situations this was.

---

## Give it back

```sql
select * from set_external_connection_status(
  'c0de0000-0000-4000-a000-000000000408',
  'active',
  'restored after <whatever it was>'
);
```

If you also revoked the OAuth grant, Mandy has to sign in again in Codex — the tools will
prompt her. Nothing needs reinstalling and no configuration changes.

---

## Who can do this

Only the connection owner — the account that created it (`created_by`). The function checks
this itself rather than trusting RLS, so it is enforced even though the function runs with
elevated rights. Mandy cannot disable or re-enable her own connection, and cannot flip anyone
else's. That is deliberate: the kill switch belongs to the person who granted the access.

---

## Working out what happened

Everything the connection did is in `external_connection_audit_log`. It records **what was
attempted and how it resolved, never the content** — there is deliberately no column that
could hold a title, comment body, medication note, prompt or token.

Recent activity, newest first:

```sql
select created_at, tool_name, resource_name, operation, outcome, reason_code, result_rows
from external_connection_audit_log
where connection_id = 'c0de0000-0000-4000-a000-000000000408'
order by created_at desc
limit 100;
```

Everything that was refused, and why:

```sql
select created_at, tool_name, resource_name, operation, reason_code
from external_connection_audit_log
where connection_id = 'c0de0000-0000-4000-a000-000000000408'
  and outcome <> 'allowed'
order by created_at desc;
```

Shape of the traffic by hour, no identifiers:

```sql
select * from external_connection_activity_metrics
where connection_id = 'c0de0000-0000-4000-a000-000000000408'
order by hour desc;
```

Reason codes you will see: `ok`, `not_a_project_member`, `rate_limited`, `connection_disabled`,
`connection_revoked`, `connection_expired`, `upstream_failure`.

---

## Narrowing instead of cutting

If the problem is one project rather than the whole connection, remove the membership. Access
to that project stops immediately; every other project is untouched, with no redeploy:

```sql
delete from project_members
where user_id = '0dd94a9f-1890-48b0-9e4f-a4bbfff949f0'
  and project_id = '<the project to remove>';
```

Verified: dropping one membership took her visible work items in that project from 101 to 0
while a second project stayed at 6.

---

## If she is being rate limited and should not be

Limits live in `external_connection_limits`. The row with `tool_name` null is the
per-connection aggregate — that is the one that stops a caller evading a per-tool limit by
rotating tools, and it is usually the one that has tripped.

```sql
select * from external_connection_limits;
```

Defaults are 600 calls/hour overall. `external_connection_precheck` returns
`retry_after_seconds` so you can tell her when it clears rather than guessing.

---

## What this cannot do

- It cannot un-send data already read. Cutting access stops the next call, not the last one.
- It cannot reach Jason's own dashboards or agents. This connection is Mandy's Codex access
  only; nothing here affects the boards, the Classroom sync, or any internal agent.
