# Migrations under version control

**SB-434.** These files are exported from the hosted project's migration history
(`supabase_migrations.schema_migrations`), which until now was the only place they existed.

## What is here, and what is not

This directory holds **18 of the project's 240 applied migrations** — everything from
2026-09-05 onward, which covers the entire family-MCP security initiative:

| Range | Tickets |
|---|---|
| SB-408 → SB-434 (15 files) | the registry, OAuth-aware RLS, role gating, the SECURITY DEFINER view fix, agent profiles and grants, the gateway routines, the audit layer |
| 3 earlier files | CLSRM-14/15 and SB-429 membership RLS |

**The 222 migrations before 2026-09-05 are not here.** They are ~509 KB of SQL going back to
March 2026, and they remain only in the hosted project.

## Why the export stopped where it did

Every file here was transcribed through an agent session, because this container has `psql`
but no database credentials, and the Supabase CLI is not installed. That is a poor tool for
bulk export: it is slow, and it can silently corrupt content.

So each file is verified: its md5 is compared against `md5(array_to_string(statements, E';\n'))`
computed in the database. All 18 match. The check caught one real error during the export — a
file that lost its final `;` to a quoting mistake — which is exactly the failure mode that
would otherwise have produced a backup that looks fine and does not run.

**The remaining 222 should be pulled with the CLI, not transcribed:**

```
supabase link --project-ref hzqqvbvhnzmgqivfigej
supabase db pull
```

Run from a machine that has the CLI and the database password. That is minutes of work and
carries no transcription risk at all. Tracked as a follow-up on SB-434.

## What this directory does and does not prove

It **does** give the recent security work a diff and a review surface, which is what SB-434 was
filed for. SB-409 shipped a defect (SB-433) that a two-line diff review would plausibly have
caught; there was no file to review.

It does **not** yet reproduce the database from scratch. That needs the full history and a
branch to replay it into, and a Supabase branch is a paid resource — the decision to spend
belongs to the project owner.

## Verifying this directory

```sql
select version || '_' || name || '.sql=' || md5(array_to_string(statements, E';\n'))
from supabase_migrations.schema_migrations
where version >= '20260905000000'
order by version;
```

Compare against `md5sum *.sql`. Last verified 2026-09-09: 18 checked, 0 mismatches.
