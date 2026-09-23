# Edge function sources

Ten edge functions are ACTIVE on `hzqqvbvhnzmgqivfigej`. Nine of them have their
source here. This file records where that source came from, what has been
checked, and — more usefully — what has **not**.

## Inventory

| Function | Deployed | `verify_jwt` | Source here | Captured under |
|---|---|---|---|---|
| `family-codex-mcp` | v3 | false | yes | SB-411 |
| `lce-cleanup` | v2 | false | yes | SB-493 |
| `supabrain-sweep` | v3 | false | yes | SB-482 |
| `agent-runner` | v10 | false | yes | SB-501 |
| `analyze-image` | v11 | false | yes | SB-501 |
| `generate-skill-embeddings` | v7 | false | yes | SB-501 |
| `generate-memory-embeddings` | v2 | false | yes | SB-501 |
| `search-skills` | v2 | false | yes | SB-501 |
| `test-key` | v9 | **true** | yes | SB-501 |
| `lce-image-ingest` | v1 | false | **no — see below** | blocked on SB-497 |

Before SB-501 the default branch carried **no** `supabase/functions/` directory
at all; the three earlier captures existed only on unmerged feature branches.

## `lce-image-ingest` is deliberately absent

Its deployed source declares its auth token as a literal constant. Committing it
verbatim would publish a live credential to a **public** repository — which is
precisely SB-440, the incident that caused the scanner in `scripts/` to exist.

The two ways to cover it are both wrong today:

- commit it as-is → republish the credential;
- commit it with the literal edited out → the file no longer matches what runs,
  which reads as coverage while being false. That is worse than an absent file,
  because an absent file is honestly absent.

So the order is forced: **SB-497 moves that token out of source first**
(the `*_token_matches()` Vault pattern already used by `lce-cleanup`,
`agent-runner` and `supabrain-sweep`), the function is redeployed, and the
redeployed source — which by then holds no secret — is captured here. Until
then this table says `no` on purpose.

`scripts/secret-scan.py` enforces this rather than trusting anyone to remember:
a commit reintroducing that shape is refused.

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
| `search-skills` | `90e00d061e3ee120` | 3109 | 107 |
| `supabrain-sweep` | `132d9efbd544ca8f` | 16428 | 365 |
| `test-key` | `1ae26f5d41034cf4` | 833 | 20 |

Regenerate and compare:

```bash
for d in supabase/functions/*/; do
  f="$d/index.ts"; [ -f "$f" ] || continue
  printf '%-28s %s\n' "$(basename "$d")" "$(sha256sum "$f" | cut -c1-16)"
done
```

Byte counts and character counts differ wherever a file uses em dashes or
arrows — several of these do. Compare the checksum, not `wc -c`. (CLSRM-34
recorded that exact false positive on day one.)

## Two observations recorded, not fixed here

Neither is in SB-501's scope; both were found while reading these sources.

1. **`search-skills` and `generate-skill-embeddings` accept an API key in the
   request body** — `Deno.env.get("OPENAI_API_KEY") || body.openai_api_key` —
   on endpoints with `verify_jwt=false`. A caller-supplied credential on an
   unauthenticated endpoint means the key reaches the platform's request logs.
2. **`test-key` is a 410 Gone stub that is still ACTIVE.** Its own comment, from
   2026-04-19, asks for it to be deleted from the dashboard. It is the only one
   of the ten with `verify_jwt=true`, so the stub is not publicly callable, but
   a retired function that is still deployed is still an endpoint.

## Deployment

Deploying from these files is **not** wired up and is not implied by their
presence. They are a record. Deployment remains whatever it has been, and a
change here reaches production only when someone deploys it deliberately.
