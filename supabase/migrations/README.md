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
