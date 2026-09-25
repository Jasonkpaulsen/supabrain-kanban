# Edge function sources

Ten edge functions are ACTIVE on `hzqqvbvhnzmgqivfigej`. All ten have their
source here. This file records where that source came from, what has been
checked, and — more usefully — what has **not**.

## Inventory

| Function | Deployed | `verify_jwt` | Source here | Captured under |
|---|---|---|---|---|
| `family-codex-mcp` | v4 | false | yes | SB-411, SB-182 |
| `lce-cleanup` | v2 | false | yes | SB-493 |
| `supabrain-sweep` | v3 | false | yes | SB-482 |
| `agent-runner` | v10 | false | yes | SB-501 |
| `analyze-image` | v11 | false | yes | SB-501 |
| `generate-skill-embeddings` | v7 | false | yes | SB-501 |
| `generate-memory-embeddings` | v2 | false | yes | SB-501 |
| `search-skills` | v2 | false | yes | SB-501 |
| `test-key` | v9 | **true** | yes | SB-501 |
| `lce-image-ingest` | v3 | false | yes | SB-497, SB-506 |

Before SB-501 the default branch carried **no** `supabase/functions/` directory
at all; the three earlier captures existed only on unmerged feature branches.

## `lce-image-ingest`: closed 2026-09-23

This section previously recorded why the function was **absent**: its deployed
source declared its auth token as a literal, so committing it verbatim would
have republished a live credential to a public repository — SB-440 exactly —
while committing it redacted would have produced a file that no longer matched
what runs. Both are wrong, so the ordering was forced: rotate first, capture
second.

SB-497 did that. The token now lives in Vault, the function asks
`public.lce_image_ingest_token_matches()` and holds nothing, and the redeployed
v2 source carries no secret — so it is captured here like the rest.

Verified by measurement, not inference: old token → **403**, the Vault token →
**400 `no path`** (through the gate, stopped before any upload), garbage → 403,
and no `x-token` header at all → 403. The probes deliberately omitted `?path`
so a successful authentication could not write anything; the bucket still holds
13 objects with the most recent dated 2026-06-28.

`scripts/secret-scan.py` still refuses the old shape, so a commit reintroducing
a literal token here is blocked rather than trusted to review.

## How these were captured, and the limit of it

Read back from the platform through the management API
(`get_edge_function`, which returns `files[].content`) and written to disk.
They are not transcriptions from memory or reconstructions from the dashboard.

**What is not established: byte-parity with the deployed bundle.**
`ezbr_sha256` is a hash of the *built bundle*, not of `index.ts`, so nothing in
a container without the Supabase CLI can re-derive it and compare. The honest
claim is "this is what the management API returned for the deployed version on
2026-09-23", not "this is byte-identical to what executes".

Closing that gap needs the CLI, on a machine that has it:

```bash
supabase functions download <slug> --project-ref hzqqvbvhnzmgqivfigej
diff -u supabase/functions/<slug>/index.ts <downloaded>/index.ts
```

Until someone runs that, treat these as high-confidence copies, not proofs.
This distinction is the whole lesson of SB-490 and TC-SB481-V4: coverage that
is *asserted* rather than *measured* is the failure mode, not the absence of
coverage.

## Drift check

These files are a **one-way mirror**, the same contract as
`classroom-mcp/automation/school-monitor-prompt.md` (CLSRM-34). The platform
wins every disagreement, because the platform is what serves traffic. Editing a
file here changes nothing until someone deploys it.

Recorded at capture (2026-09-23), `sha256` truncated to 16 hex chars:

| Function | sha256[0:16] | bytes | lines |
|---|---|---|---|
| `agent-runner` | `8edf743413fcfa63` | 17013 | 306 |
| `analyze-image` | `ff6a76e8737c6fbe` | 9009 | 254 |
| `family-codex-mcp` | `28ca14d0c70a4a45` | 44666 | 698 |
| `generate-memory-embeddings` | `af5062453db5f793` | 3563 | 62 |
| `generate-skill-embeddings` | `140b39cbd4d442d6` | 4388 | 156 |
| `lce-cleanup` | `25ac19af2ec7b471` | 5074 | 83 |
| `lce-image-ingest` | `3e161930acc90bdf` | 3385 | 69 |
| `lce-image-ingest/path.ts` | `202ae0b293706998` | 3052 | 62 |
| `search-skills` | `90e00d061e3ee120` | 3109 | 107 |
| `supabrain-sweep` | `132d9efbd544ca8f` | 16428 | 365 |
| `test-key` | `1ae26f5d41034cf4` | 833 | 20 |

`lce-image-ingest` is the only multi-file function: `index.ts` imports
`path.ts`, and both are deployed. `path.test.ts` sits beside them and is NOT
deployed -- it runs in CI (`.github/workflows/function-tests.yml`).

Regenerate and compare:

```bash
# Every deployed .ts file, not just index.ts -- lce-image-ingest also ships
# path.ts, and a loop over index.ts alone would skip it without saying so.
find supabase/functions -name '*.ts' ! -name '*.test.ts' | sort | while read -r f; do
  printf '%-45s %s\n' "${f#supabase/functions/}" "$(sha256sum "$f" | cut -c1-16)"
done
```

Byte counts and character counts differ wherever a file uses em dashes or
arrows — several of these do. Compare the checksum, not `wc -c`. (CLSRM-34
recorded that exact false positive on day one.)

## Three observations recorded at capture

None was in the scope of the ticket that found it; all three came from reading
these sources rather than from review of a change. The third has since been
fixed; the first two remain open as SB-503 and SB-504.

1. **`search-skills` and `generate-skill-embeddings` accept an API key in the
   request body** — `Deno.env.get("OPENAI_API_KEY") || body.openai_api_key` —
   on endpoints with `verify_jwt=false`. A caller-supplied credential on an
   unauthenticated endpoint means the key reaches the platform's request logs.
2. **`test-key` is a 410 Gone stub that is still ACTIVE.** Its own comment, from
   2026-04-19, asks for it to be deleted from the dashboard. It is the only one
   of the ten with `verify_jwt=true`, so the stub is not publicly callable, but
   a retired function that is still deployed is still an endpoint.
3. ~~**`lce-image-ingest` interpolates a caller-supplied `path` into the storage
   URL, and `..` escapes the bucket.**~~ **Resolved by SB-506, v3,
   2026-09-23.** `path.ts` validates in two independent layers -- an allowlist
   policy and a parsed-pathname invariant -- tested against every object name
   in the bucket (so no real caller breaks) and mutation-tested (six mutants,
   six killed). Verified live: every recorded escape now returns 400 with a
   specific reason, and nothing was written.

## Deployment

Deploying from these files is **not** wired up and is not implied by their
presence. They are a record. Deployment remains whatever it has been, and a
change here reaches production only when someone deploys it deliberately.
