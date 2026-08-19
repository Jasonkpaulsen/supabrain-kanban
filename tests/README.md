# End-to-end test suite

Playwright suite covering the kanban board UI, split into three batches that
mirror the QA batch tickets:

| Batch | Ticket | Tag | Scope |
|---|---|---|---|
| 1 | SB-339 | `@batch1` | Static render & analytics surfaces (read-only) |
| 2 | SB-340 | `@batch2` | Filter, search, session & performance |
| 3 | SB-341 | `@batch3` | Mutating CRUD & drag-drop |

Only batch 1 exists so far.

## Running

```bash
npm install
npm run test:batch1
npm run test:report   # HTML report from the last run
```

## Configuration

The suite reads two environment variables and refuses to run without them —
no credentials are committed:

```bash
export QA_FIXTURE_EMAIL='...'      # the QA fixture user
export QA_FIXTURE_PASSWORD='...'
```

The fixture user owns a seeded board: 25 work items across 2 projects, 2 agents,
2 labels. Tests assert against those exact counts, so re-seeding changes
expectations.

## Transport modes

`tests/e2e/stub.js` intercepts Supabase REST and auth calls and replays the
payloads in `tests/e2e/fixtures/board-payload.json`, which were dumped verbatim
from the seeded fixture under the fixture user's RLS context.

This exists because CI runners without outbound network access cannot reach
`supabase.co` or `cdn.jsdelivr.net`. Under the stub, rendering logic is fully
exercised in a real browser, but **the live HTTP round trip is not** — that is
covered by TC-SB116 and TC-SB119 in batch 2, which require real egress.

Set `E2E_LIVE=1` to skip the stub and drive the real backend. It is wired up in
`stub.js`: live mode still serves the vendored supabase-js bundle (live mode is
about the real backend, not the real CDN) but stops intercepting `/auth/v1/**`
and `/rest/v1/**`.

Live mode needs three things that the sandboxed runner does not have:

1. egress to `*.supabase.co` — the agent proxy answers 403 to CONNECT by default;
2. `QA_FIXTURE_EMAIL` and `QA_FIXTURE_PASSWORD` for a fixture user that can
   actually sign in;
3. the fixture projects un-archived, or the board renders empty and TC-SB116's
   RLS assertion has nothing to check:
   `update public.projects set archived = false where meta->>'qa_fixture' = 'true';`

`installWriteStubs` (batch 3) throws under `E2E_LIVE=1` on purpose — that batch
mutates and has no live-safe mode.

## Where results go

Results are recorded in Supabase, not just in the HTML report:

- `test_cases` — `last_result`, `status`, `last_evidence`, `test_count`
- `test_runs` — one row per execution, with evidence, duration and transport notes

A failing case blocks its ticket's QA gate, so record honestly: a stubbed run is
noted as stubbed in the `test_runs.notes` column.
