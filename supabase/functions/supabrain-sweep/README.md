# supabrain-sweep (SB-482)

One token-gated HTTP endpoint for the recurring board sweeps, so a scheduled
task can run a sweep with a single `web_fetch` instead of a series of
`execute_sql` calls that stall on a tool-approval prompt with nobody at the
keyboard.

`POST https://<project>.supabase.co/functions/v1/supabrain-sweep`

## It does not accept SQL

SB-482 asks for "all sweep SQL operations behind a single HTTP endpoint …
parameterized queries for all three sweep types". Read literally that is a
SQL-over-HTTP gateway holding the service-role key behind one bearer token.
This project has already published three live tokens (SB-408, SB-440,
SB-447), and `lce-cleanup` still carries its token as a literal in both its
source and `cron.job.command`. A leak of this token, if it took arbitrary SQL,
would be equivalent to handing over the database.

So the caller **names an operation** and passes typed parameters. The SQL lives
in `index.ts`, fixed, and is never assembled from caller input. Adding a
capability means editing the allow-list and redeploying — a reviewable change —
not sending a different string. An unknown operation is a `400` listing the
valid names; there is no fallthrough that executes anything, and one bad name
rejects the whole request rather than silently running a subset.

## Auth

`x-token` header, checked against Vault through
`public.supabrain_sweep_token_matches()`. Following SB-440, this function holds
no literal token and the database never returns the secret — the RPC answers
only true/false and is EXECUTE-granted to `service_role` alone.

The secret `supabrain_sweep_token` was created out of band with a value
generated inside the database and has never been rendered to a transcript, a
migration or a commit. It is deliberately absent from
`20260921011023_sb482_supabrain_sweep_token_helpers.sql`; see that file's
header. A rebuilt copy gets the two functions and no secret, so the token check
fails closed — correct, because a fresh environment must be given its own token.

`verify_jwt` is **off**, as on `agent-runner`. Turning it on would require every
caller to also present the project anon key, which is public anyway (SB-182) and
so adds no real control, while coupling this endpoint to a key SB-182 exists to
rotate.

To rotate: `select vault.update_secret(id, '<new>')` for that secret. Nothing
else changes — the function reads it by name on every request.

## Calling it

```jsonc
{"describe": true}                                  // list operations, bundles and each operation's parameters
{"bundle": "pm-triage-dispatch"}                    // run a named bundle
{"bundle": "process-engineer-daily", "dryRun": true} // skip everything that mutates
{"operations": ["stale_wip"], "params": {"staleDays": 7}}
{"operations": ["backlog_grooming_report", "stale_wip"],
 "params": {"stale_wip": {"staleDays": 2}}}          // per operation, when a name is ambiguous
```

### Parameters (SB-495)

Each operation declares its parameters and what each one means (`describe`
lists them). Parameters can be given flat, `{"staleDays": 7}`, or per operation,
`{"stale_wip": {"staleDays": 7}}`. A per-operation value overrides a flat one.

A flat name is accepted only when every operation in the call that reads it
means the same thing by it. `staleDays` is "days a backlog item has gone
untouched" (default 45) to `backlog_grooming_report` but "days open work has
gone untouched" (default 3) to `stale_wip` and `blocked_items`. So
`{"operations":["backlog_grooming_report","stale_wip"],"params":{"staleDays":2}}`
is refused with a `400` naming both meanings. Before SB-495 it was accepted and
quadrupled the grooming report (195 items against its default 54).

Also refused with a `400`, where v3 silently fell back to the default:

- a parameter no operation in the call reads (a typo such as `staleday`);
- a non-numeric value;
- a per-operation block for an operation that is not in the call.

Out-of-range numbers are still clamped to the operation's range. The response's
`params_used` shows the effective values, so a clamp is visible.

### Truncation (SB-495)

Every list read asks the database for its exact count of matching rows, so a
result cut short by a limit (500 rows, or 5000 on the per-agent work-item scan)
or by the API's own row cap reports `truncated: true` with the real `total`.
The response lists any such operation in a top-level `truncated` array with a
`warning`, and `complete` is `true` only when nothing failed and nothing was
cut short. `ok` keeps its old meaning: no operation failed.

From SQL (this is how `pg_cron` would call it, and the token never leaves the
database):

```sql
select net.http_post(
  'https://<project>.supabase.co/functions/v1/supabrain-sweep',
  '{"bundle":"management-agent-sweep"}'::jsonb, '{}'::jsonb,
  public.supabrain_sweep_headers());
```

Every operation declares whether it mutates. `dryRun: true` runs the read-only
ones and reports the mutating ones in `skipped_because_dry_run`, so a caller can
see what a sweep would touch before letting it touch anything. A failing
operation lands in `failed` and returns `207`; the others still return their
results, because a sweep reporting four findings and one error is more useful
than a 500.

## Bundles

| Bundle | Operations |
|---|---|
| `process-engineer-daily` | `qa_shiftleft_sweep`, `review_sla_sweep`, `cron_health_check`, `backlog_grooming_report` |
| `management-agent-sweep` | `agents_missing_chain`, `agent_load`, `agents_idle_with_queue` |
| `pm-triage-dispatch` | `untriaged_items`, `review_queue_aging`, `stale_wip`, `blocked_items`, `awaiting_human` |

The four `process-engineer-daily` operations are existing SECURITY DEFINER
functions granted to `service_role` only. This endpoint calls them; it does not
reimplement them. All four write, so a `dryRun` of that bundle runs nothing.
`backlog_grooming_report` was declared read-only until SB-495, but the database
function inserts an `activity_log` row on every call, so a dry run wrote one.

## Tests

`params.test.ts` tests the parameter resolver and the truncation check in
`params.ts`, the module that ships. It includes the architect's reproduction as
its first case. CI runs it through `.github/workflows/function-tests.yml`.
Locally:

```sh
node --experimental-strip-types --test supabase/functions/supabrain-sweep/params.test.ts
```

Deploy `index.ts` and `params.ts` together, with `verify_jwt` off. The test file
is not deployed.

## A defect this found in itself

The first version of `agents_missing_chain` filtered on `automation_enabled`
alone and reported six agents with no reporting line. Four were
`status = 'archived'` and the other two were seeded QA fixtures
(`meta.qa_fixture`). The true count is zero — so the management sweep would have
raised six false gaps every day, which is exactly SB-376, where handoff
detection measured the wrong field and produced 29 false positives.

Fixed by a shared `liveAgents()` filter so all three management operations agree
on who counts, and the excluded number is reported as
`excluded_archived_or_fixture` rather than silently dropped. Found by running
the endpoint against production before shipping it, not by review.

## Scope note

The three consuming sweeps (`pm-triage-dispatch`, `management-agent-sweep`,
`process-engineer-daily`) are local Cowork scheduled tasks on Jason's Mac;
`list_triggers` does not return them and their SKILL.md files are not in this
repo, so their exact current SQL could not be read when this was built. The
operations here are derived from the database. SB-483/484/485 rewrite those
SKILL.md files against this endpoint and will establish whether any operation is
missing; adding one is an edit to the allow-list plus a redeploy.
