# ADR-CRM-003: CRM search, duplicate candidates and reviewed merge

- **Status:** Accepted (System Architect, 2026-10-02)
- **Epic:** SB-466 (CRM — Search, Data Quality & Duplicate Management)
- **Build tickets:** SB-469 (search), SB-468 (duplicate candidates), SB-467 (reviewed merge)
- **Builds on:** ADR-CRM-001, ADR-CRM-002. Their rules apply unchanged.

## 1. Decision in one paragraph

- **Search:** one function, `crm_search(query)`, looks across names, contact values,
  organizations, relationship types, tags and notes, and reports which field matched and why.
- **Duplicates:** proposed by a function from shared contact values and similar names, with
  supporting context and plain reasons. A person can dismiss a proposed pair; nothing is ever
  merged automatically.
- **Merge:** a single explicit call that needs a reason code. It moves everything onto the kept
  person, preserves every row's provenance, and keeps the merged person as an archived record
  pointing at the one it was merged into. It writes a merge log and an audit row.

## 2. Normalization and indexes (SB-469)

- `pg_trgm` is installed in `extensions`, like every other extension here.
  - **Corrected during build:** Supabase creates extension functions as `supabase_admin`, with
    EXECUTE granted to PUBLIC. The SB-488 default (objects created by `postgres`) therefore does
    not apply, and `postgres` cannot revoke that grant.
  - This is acceptable because pg_trgm's functions are pure string computations that read no
    table, the same as `fuzzystrmatch` (CLSRM-40).
  - The migration asserts what matters: `authenticated` can call them, and `crm_search` itself
    is not callable by `anon`.
- `crm_people.name_normalized` and `crm_organizations.name_normalized` are generated columns:
  lowercase, trimmed, internal whitespace collapsed. Each has a trigram GIN index.
- Accent folding (`unaccent`) is deliberately not used yet: it is not immutable, so it cannot
  back a generated column without a wrapper. Recorded as a follow-up, not a gap.
- Contact values already have `value_normalized` (SB-453). This adds a prefix index for
  "starts with" lookups.
- Notes are searched with full-text search (`simple` configuration, which handles names and
  mixed languages) over:
  - `crm_facts.value`;
  - `crm_interactions.title || summary`.

  The partial GIN indexes cover **normal and private rows only**, which is also the search
  boundary (§3).
- **Corrected during build (performance, §6):** both note sources store their vector as a
  generated column, `search_tsv`, and `crm_search` compares that column instead of calling
  `to_tsvector()` per row. See §6 for why.
- **Corrected during build:** the four search GIN indexes use `fastupdate = off`. A personal
  CRM is write-light and read-heavy, and a pending list made every search scan unindexed rows.

- **Corrected during build:** no function pins `pg_trgm.similarity_threshold`. Postgres refuses
  that SET clause (permission denied) once the module is loaded.
  - Search uses the `%` operator at its default of 0.3, which is index-assisted.
  - Duplicate detection adds an explicit `similarity() >= 0.6` filter.

## 3. Search contract (SB-469)

```
crm_search(query text, max_results int default 25)
  → person_id, display_name, matched_on, match_detail, rank
```

- `matched_on` is one of `name`, `email`, `phone`, `handle`, `url`, `other`, `organization`,
  `relationship`, `tag`, `note`.
- `match_detail` says what matched, for example "Example Corp (Engineer)" or "parent of Avery".
- `rank` exists for ordering only. It is never stored.

How each field matches:

| Field | Matches on |
|---|---|
| Name | Trigram similarity, or contains |
| Contact | Exact normalized value, or prefix of 3+ characters. Phones compare digits only |
| Organization | Similar name; returns people affiliated now or in the past |
| Relationship | Type label or code; directional types match the correct side (`child` finds children) |
| Tag | Name, exact or prefix |
| Note | Full text, normal and private only |

Other rules:
- Archived and merged people are excluded.
- **Search is for a signed-in user.** It filters on `user_id = auth.uid()` explicitly, not only
  through RLS, so a service-role caller with RLS bypassed gets nothing rather than everyone.
- Restricted (sensitive / highly_sensitive) notes are never searchable. Agents reach them only
  through the audited `*_for_agent` functions.

## 4. Duplicate candidates (SB-468)

`crm_duplicate_candidates(max_results default 100)` returns:
- `person_a`, `person_b` (canonical order `a < b`);
- both names;
- `strength`: `strong` or `possible`;
- `reasons text[]`.

**Corrected during build (performance, §6): blocking.** Names are compared only within blocks,
not every person against every other. Two people share a block when they share a name word, or
that word's double-metaphone code (`fuzzystrmatch`). Every pair the rules care about shares one:
Katherine/Catherine *Holloway*, Jonathan/Jonathon *Marlowe*, Jon/John (both `JN`). A key shared
by more than 200 people (a very common first name) is not used as a block; those people still
pair through their other words. Scoring and reasons are unchanged.

Reasons that make a pair a candidate:
- **Strong:** the same normalized email, phone or handle on both people.
- **Possible:** name similarity ≥ 0.6 together with supporting context: the same normalized
  name, the same birthday, or a shared organization. Or name similarity ≥ 0.8 on its own.

Context alone (a shared employer, a shared birthday) never makes a candidate: it would flag
every colleague.

Other rules:
- Pairs that have been dismissed are excluded, and so are archived and merged people.
- `crm_duplicate_dismissals` is an owned table: one live row per pair, with a reason code.
  Archiving a dismissal un-dismisses it.
- `crm_dismiss_duplicate(a, b, reason default 'not_same_person')` writes the pair in canonical
  order.
- Computing candidates writes nothing. No trigger, cron job or function merges people
  automatically.

## 5. Reviewed merge (SB-467)

```
crm_merge_people(keep_id, merge_id, reason_code) → merge_log id
```

It is SECURITY INVOKER, so it can only see and move the caller's own rows. Both people must be
live, distinct and visible. The reason must be a snake_case code.

1. **Move.** Every reference to `merge_id` moves to `keep_id`, archived history included:
   - contact points, addresses, both sides of relationships, affiliations, group memberships,
     tags, important dates, facts, interaction participation and actions;
   - each moved row keeps its own provenance (`source_type`, `source_ref`, `confidence`,
     `captured_at`) untouched.
2. **Conflicts.** A row that cannot move without breaking a rule stays on the merged person and
   is archived, so it remains as history. Rules that can block a move:
   - a duplicate email, group membership or participation;
   - a relationship between the two people, which would become a self-link.

   A "preferred" contact point or address that would clash with the kept person's preferred
   one moves as not-preferred.
3. **Fill blanks.** The kept person's empty name parts, pronouns, cadence and priority are
   filled from the merged person. Nothing set on the kept person is overwritten.
4. **Retire.** The merged person is archived, with `merged_into_id = keep_id` and `merged_at`.
   A check makes "merged but not archived" impossible.
5. **Record.** `crm_merge_log` gets one row with:
   - both ids;
   - the merged person's display name, so the source stays identifiable;
   - the reason code;
   - per-table counts of moved and archived rows.

   The log is append-only, has no FKs (like the audit log, so it survives anything it refers
   to), and is owner-readable. `crm_audit('merge', …)` is written too.

Unmerge is not automated. The merge log, plus the archived rows still on the merged person, is
what a manual reversal would use.

## 6. Performance target (personal-CRM scale)

At 5,000 people, 15,000 contact points, 500 organizations, 20,000 interactions and 10,000 facts
for one owner:
- `crm_search`: median under 100 ms, worst under 250 ms, across representative queries of every
  kind;
- `crm_duplicate_candidates`: under 3 s.

These are validated by `supabase/tests/crm_search_perf.sql` on production. It generates the
data, analyzes it, measures, and rolls everything back.

### Result on production (2026-10-02)

| Measure | First run | After the fixes | Target |
|---|---|---|---|
| `crm_search` median | ~220 ms | 42 ms | < 100 ms |
| `crm_search` worst | ~230 ms | 55 ms | < 250 ms |
| Duplicate scan | 2.0 s at 1,000 people, growing much faster than linear | 2.1 s at 5,000 people, exactly the 50 planted pairs | < 3 s |

**Why search was slow.** Under row-level security, Postgres will not let a qualifier that is
not leakproof drive an index scan. Full-text `@@`, trigram `%` and `LIKE` are all not leakproof.
So every branch of `crm_search` is a sequential scan of the owner's rows, and the notes
branches were rebuilding `to_tsvector()` for 30,000 rows on every call. Stored vectors remove
that rebuild. The scans remain, and at personal-CRM scale they are well inside the target.

**Option considered and not taken: running `crm_search` with owner rights.** Making
`crm_search` `SECURITY DEFINER` would let the indexes drive the scan, so latency would stop
growing with row count. It would also move user isolation from the database's RLS policies
to the function's own `user_id = auth.uid()` filters, which weakens a guarantee ADR-CRM-001
relies on. It is not done. Revisit only if a real owner's data outgrows the target, and only
with Jason's approval.

