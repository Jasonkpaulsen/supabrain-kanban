# Management Agent Sweep: escalation rules

Source of truth: ADR-FLOW-005 D6-D8 (SB-554, SB-526). This file is the rule text for the
`management-agent-sweep` and `weekly-license-sentinel-audit` skills on Jason's Mac. Sync it
into both SKILL.md files **before** either enforcement switch is flipped; until then the
sweeps keep their old escalation rules and the database only warns.

Both gates ship in `warn` mode. `select public.escalation_gate_mode('SB-554'),
public.escalation_gate_mode('SB-526');` returns `warn` until Jason approves the ticket.
In `warn` mode nothing is refused: the row is stamped and a WARNING is raised. After a
flip to `enforce`, the cases below marked **refused** raise an error and the write fails.

## 1. Before creating an ESCALATION, classify the subject

```sql
select public.jason_blocker_class(array['SB-413']);   -- the ticket codes the escalation is about
```

| Result | Meaning | Action |
|---|---|---|
| `human_decision` | A subject waits on Jason: it is `awaiting_jason`, a pending L2+ or proposal approval, flagged `requires_jason` / `needs_jason`, or is blocked one hop up by such an item. | **Do not create the escalation.** The item is already in `vw_jason_decision_digest` / `jason_decision_digest()`. Mention it in the digest section of the sweep report. In enforce mode this insert is **refused** (`P0554`, `ESCALATION-003`). |
| `agent` | An open subject that an agent can move. | Escalate if the normal rule says so (sections 2-3). |
| `unresolved` | No open subject matches the codes (unknown, done or cancelled). | Do not escalate; fix the reference or drop the finding. |

An escalation created with `authority_level >= 3`, `status = 'awaiting_jason'` or
`meta.flagged_for_jason = 'true'` is always `human_decision`, whatever its subject.

Read Jason's queue in one call:

```sql
select public.jason_decision_digest();                 -- {total, by_priority, breached, oldest_days, noop_escalations, items}
select * from public.vw_jason_decision_digest order by rank;
```

Aging thresholds: critical 3 days, high 7, medium 14, low 30. Items waiting on an outside
party (`meta.awaiting_external`) are not Jason decisions and are not listed.

## 2. Name the subject, and one escalation per upstream

- Always set `meta.upstream_ticket` to the ticket being escalated. The closure gate resolves
  the upstream from `meta.upstream_ticket`, then `meta.escalates`, then the first ticket
  code in the title. An escalation with no resolvable upstream is invisible to the gate and
  to the audit.
- Before creating one, look for an open escalation on the same upstream:

  ```sql
  select ticket_code, status from public.vw_escalation_closure_audit
   where row_kind = 'escalation' and upstream_code = 'SB-413' and status not in ('done', 'cancelled');
  ```

  If one exists, **comment on it** instead of filing another.
- A re-escalation after an earlier one closed sets `meta.prior_escalation` to the earlier
  ticket code.

## 3. Closing an escalation

Close an escalation as `done` only when the audit says `ok`:

```sql
select ticket_code, verdict, upstream_code, upstream_status, open_blockers, unowned_blockers, comments_after
  from public.vw_escalation_closure_audit where ticket_code = 'SB-520';
```

| Verdict | Meaning | Action |
|---|---|---|
| `ok` | The upstream is finished or no longer stuck, or it has re-verification evidence: a comment on the upstream after the escalation was created, an owned upstream, at least one open blocker, every open blocker owned, and the escalation is not itself the blocker. | Close as `done`. |
| `held` | Closing now would be ESCALATION-001 (no re-verification evidence) or ESCALATION-002 (nothing changed since `meta.escalation_snapshot`). | Re-verify the upstream first: comment on it, make sure it and its blockers have an owner. In enforce mode the close is **refused** (`P0001`). |
| `violation` | Already `done` while the upstream is still stuck. | Report it; do not reopen it yourself. |
| `governance_violation` (upstream rows) | The upstream has been blocked for more than 14 days and has a done escalation in its history. | Report it to Jason in the sweep. |

- **Never** set any `*_exempt` flag to get a close through. The gate does not read them.
- A duplicate escalation is closed by cancelling it, not by marking it done:

  ```sql
  select public.cancel_work_item(<escalation id>, 'duplicate', '<one-line reason>', '<surviving ticket code>', '<your role>');
  ```

## 4. What the database stamps

| Key | Written by | When |
|---|---|---|
| `meta.blocker_class`, `meta.digest_routed`, `meta.classified_by = 'SB-554'` | `trg_escalation_blocker_class` | Insert of an ESCALATION-titled row |
| `meta.escalation_snapshot` (upstream, status, assignee, blockers, at) | `trg_escalation_closure` | Insert of an escalation with a resolvable upstream |
| `meta.escalation_closure` (verdict, upstream, at) | `trg_escalation_closure` | A held close in `warn` mode |

Do not write these keys yourself; a caller-supplied snapshot is ignored.
