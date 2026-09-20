# Migrations under version control

**SB-434 → SB-437.** All 240 applied migrations, fetched from the hosted project with
`supabase migration fetch` and verified against the database.

## Verifying this directory

Compute an aggregate over every file:

```
cd supabase/migrations
for f in *.sql; do printf '%s=%s\n' "$f" "$(md5 -q "$f")"; done | md5 -q     # macOS
for f in *.sql; do printf '%s=%s\n' "$f" "$(md5sum "$f"|cut -d' ' -f1)"; done | md5sum   # Linux
```

And the same thing from the database:

```sql
select md5(string_agg(fn || '=' || md5(array_to_string(statements, E';\n') || E';\n'),
                      E'\n' order by fn collate "C") || E'\n')
from (select version || '_' || name || '.sql' as fn, statements
      from supabase_migrations.schema_migrations) t;
```

Both give `04fe2e774dea44d19c122803b132307d` as of 2026-09-09, 240 files. One comparison
covers every file — no sampling.

Two details that will bite you if you reconstruct the expected value by hand:

- The CLI writes each statement followed by `;` and a newline. Where the stored statement
  already ends in `;`, the file contains `;;`. That is valid SQL (an empty statement) and is
  the CLI's canonical output, so leave it alone — matching it means future `migration fetch`
  runs produce no phantom diff.
- The shell pipeline emits a trailing newline after the last line; `string_agg` does not.
  Hence the `|| E'\n'` above. Getting this wrong makes every file look broken when nothing is.

## How this directory was built, and one thing worth knowing

SB-434 exported the first 18 files by transcribing them through an agent session, because that
container has `psql` but no database credentials and no CLI. That worked — an md5 check per
file made corruption detectable, and it caught one file that had lost its trailing semicolon —
but it is the wrong tool for half a megabyte.

SB-437 replaced all 18 with the CLI's own output. **The comparison vindicated the
transcription**: the SQL was identical in every one. The only differences were the trailing
newline and the CLI's extra `;`. Recorded here because "the careful method held up" is worth
knowing next time someone has to choose between them.

## What is still not proven

These files have never been replayed from scratch. Byte-fidelity to the history table is not
the same as reproducing the database:

- A replay only reproduces what was applied *as a migration*. Objects created through
  `execute_sql` or the dashboard would silently not exist, and nothing here would reveal it.
- Any replay diff must cover **grants, policies and routine ACLs**, not just tables and
  columns. SB-408 and SB-433 were both privilege defects that a schema-only diff shows as
  perfectly clean.

That work is TC-SB437-V2 and V3. It needs a Supabase branch — $0.01344/hour on this
organisation's plan, so roughly three cents for a create-replay-diff-destroy cycle.

## Grants convention (SB-488, 2026-09-20)

Since migration `20260920174123_sb488_new_public_objects_start_with_no_client_access`,
a table, function or sequence created by the `postgres` role starts with **no**
`anon` or `authenticated` access. Before that, Supabase's default privileges handed
both roles ALL on every new table and EXECUTE on every new function the moment it
was created — which is how `meta_key_registry` shipped anon-writable (SB-479) and
why SB-237 had to `REVOKE ... FROM PUBLIC` before its revokes meant anything.

What a migration must now do, and did not have to before:

- **A table clients read or write through PostgREST** — `ENABLE ROW LEVEL SECURITY`,
  write the policies, then `GRANT` exactly the verbs the client needs to exactly the
  role that needs them. No grant means 42501 on the first call; that is the point.
- **An RPC clients call** — `GRANT EXECUTE ... TO authenticated` (or `anon`) after the
  `CREATE FUNCTION`. For `SECURITY DEFINER` functions, say in a comment who may call it
  and why; the daily audit reports any such function `anon` can execute.
- **Internal objects** (registries, audit tables, agent plumbing read over MCP as
  `postgres` or `service_role`) — nothing. `service_role` keeps ALL by default and
  bypasses RLS. Enable RLS anyway; the audit reports any table in `public` without it.
- **Sequences** behind `serial`/`identity` columns a client inserts into — `GRANT USAGE`
  to the inserting role, or the insert fails on the nextval.
- **`CREATE EXTENSION`** — the function half of the default is global for the
  `postgres` role (PostgreSQL offers no per-schema way to remove the built-in PUBLIC
  EXECUTE), so an extension installed after 2026-09-20 has functions clients cannot
  call until a migration grants EXECUTE on them. Extensions installed before are
  unaffected.

Existing objects were **not** changed by SB-488; every grant that existed on
2026-09-20 still exists. The daily audit (`audit_client_role_exposure`, called from
`generate_daily_audit`) compares today's client-role grants against
`security_grant_baseline` and reports anything new, once, then records it. To make it
re-raise a grant, delete that row from the baseline.

Assert your grants inside the migration, in a `DO` block that raises on failure — the
pattern in `20260920171712_sb479_lock_down_meta_key_registry`. A grant migration that
can half-apply and record is worse than none.
