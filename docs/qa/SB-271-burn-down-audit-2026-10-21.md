# Audit of the SB-271 burn-down passes (2026-10-21)

On 2026-07-12 the "SB-271 QA backlog burn-down campaign" recorded 175 test cases as passed. Each pass carried the same evidence, "Done-status verification — deployed and accepted", and none of them exercised any behaviour. One of these passes, TC-SB209-01, hid a feature that had been deleted four days earlier.

Every case was re-verified on 2026-10-21 against the live database, this repo and the e2e suite (69 passed, 1 skipped). The checks were read-only and split across four auditors, and every write was made centrally. Each case has a new `test_runs` row with execution context `SB-271 burn-down audit 2026-10-21 (re-verification)`, and that row holds the evidence. This file lists codes and verdicts only, so no project data lands in git.

## Totals

| Verdict | Cases | Recorded as |
|---|---|---|
| verified | 67 | run `pass`; case `passed` |
| regressed | 13 | run `fail` with `bug_ticket_id`; case `failed` |
| unverifiable here | 80 | run `blocked`; case `retest`. The 07-12 pass is not evidence. |
| obsolete | 15 | run `skipped`; case `retired` |

| Project | verified | regressed | unverifiable | obsolete |
|---|---|---|---|---|
| CIP | 2 | 1 | 3 | 0 |
| CS | 1 | 0 | 13 | 0 |
| DEN | 3 | 1 | 42 | 0 |
| FAM | 1 | 0 | 0 | 0 |
| KEL | 10 | 0 | 17 | 11 |
| OB | 1 | 0 | 1 | 0 |
| SB | 49 | 11 | 4 | 4 |

"Unverifiable" means the behaviour lives somewhere this audit cannot reach:

- the Denken Box iOS app;
- the KEL and CS apps;
- a device, or a signed-in browser for UAT;
- a one-off historical event.

Those cases need a human or the owning repo.

## Regressions

| Test case | Ticket | Follow-up |
|---|---|---|
| TC-CIP109-01 | CIP-109 | CIP-105 (open) |
| TC-DEN018-01 | DEN-018 | DEN-122 |
| TC-SB058-01 | SB-058 | SB-620 |
| TC-SB060-01 | SB-060 | SB-620 |
| TC-SB149-01 | SB-149 | SB-621 |
| TC-SB153-01 | SB-153 | SB-619 |
| TC-SB170-01 | SB-170 | SB-620 |
| TC-SB179-01 | SB-179 | SB-623 |
| TC-SB195-01 | SB-195 | SB-620 |
| TC-SB209-01 | SB-209 | SB-616 (fixed) |
| TC-SB212-01 | SB-212 | SB-618 |
| TC-SB217-01 | SB-217 | SB-617 |
| TC-SB256-01 | SB-256 | SB-622 |

## All cases

| Test case | Ticket | Verdict |
|---|---|---|
| TC-CIP078-01 | CIP-078 | unverifiable |
| TC-CIP109-01 | CIP-109 | regressed |
| TC-CIP110-01 | CIP-110 | verified |
| TC-CIP111-01 | CIP-111 | verified |
| TC-CIP132-01 | CIP-132 | unverifiable |
| TC-CIP136-01 | CIP-136 | unverifiable |
| TC-CS065-01 | CS-065 | unverifiable |
| TC-CS067-01 | CS-067 | unverifiable |
| TC-CS068-01 | CS-068 | unverifiable |
| TC-CS070-01 | CS-070 | unverifiable |
| TC-CS071-01 | CS-071 | unverifiable |
| TC-CS073-01 | CS-073 | unverifiable |
| TC-CS074-01 | CS-074 | unverifiable |
| TC-CS075-01 | CS-075 | unverifiable |
| TC-CS076-01 | CS-076 | unverifiable |
| TC-CS077-01 | CS-077 | unverifiable |
| TC-CS078-01 | CS-078 | unverifiable |
| TC-CS081-01 | CS-081 | unverifiable |
| TC-CS084-01 | CS-084 | verified |
| TC-CS079-01 | CS-79 | unverifiable |
| TC-DEN002-01 | DEN-002 | unverifiable |
| TC-DEN003-01 | DEN-003 | unverifiable |
| TC-DEN004-01 | DEN-004 | unverifiable |
| TC-DEN005-01 | DEN-005 | unverifiable |
| TC-DEN006-01 | DEN-006 | unverifiable |
| TC-DEN007-01 | DEN-007 | unverifiable |
| TC-DEN008-01 | DEN-008 | unverifiable |
| TC-DEN018-01 | DEN-018 | regressed |
| TC-DEN022-01 | DEN-022 | unverifiable |
| TC-DEN023-01 | DEN-023 | unverifiable |
| TC-DEN024-01 | DEN-024 | unverifiable |
| TC-DEN025-01 | DEN-025 | unverifiable |
| TC-DEN026-01 | DEN-026 | unverifiable |
| TC-DEN027-01 | DEN-027 | unverifiable |
| TC-DEN028-01 | DEN-028 | verified |
| TC-DEN029-01 | DEN-029 | verified |
| TC-DEN030-01 | DEN-030 | unverifiable |
| TC-DEN031-01 | DEN-031 | unverifiable |
| TC-DEN032-01 | DEN-032 | unverifiable |
| TC-DEN033-01 | DEN-033 | unverifiable |
| TC-DEN034-01 | DEN-034 | unverifiable |
| TC-DEN035-01 | DEN-035 | unverifiable |
| TC-DEN036-01 | DEN-036 | unverifiable |
| TC-DEN037-01 | DEN-037 | unverifiable |
| TC-DEN038-01 | DEN-038 | unverifiable |
| TC-DEN039-01 | DEN-039 | unverifiable |
| TC-DEN040-01 | DEN-040 | unverifiable |
| TC-DEN041-01 | DEN-041 | unverifiable |
| TC-DEN042-01 | DEN-042 | unverifiable |
| TC-DEN043-01 | DEN-043 | unverifiable |
| TC-DEN044-01 | DEN-044 | unverifiable |
| TC-DEN045-01 | DEN-045 | unverifiable |
| TC-DEN046-01 | DEN-046 | unverifiable |
| TC-DEN047-01 | DEN-047 | unverifiable |
| TC-DEN048-01 | DEN-048 | unverifiable |
| TC-DEN049-01 | DEN-049 | unverifiable |
| TC-DEN050-01 | DEN-050 | unverifiable |
| TC-DEN051-01 | DEN-051 | unverifiable |
| TC-DEN052-01 | DEN-052 | unverifiable |
| TC-DEN053-01 | DEN-053 | unverifiable |
| TC-DEN054-01 | DEN-054 | unverifiable |
| TC-DEN055-01 | DEN-055 | unverifiable |
| TC-DEN056-01 | DEN-056 | unverifiable |
| TC-DEN057-01 | DEN-057 | unverifiable |
| TC-DEN060-01 | DEN-060 | verified |
| TC-DEN059-01 | DEN-59 | unverifiable |
| TC-FAM019-01 | FAM-019 | verified |
| TC-KEL009-01 | KEL-009 | unverifiable |
| TC-KEL011-01 | KEL-011 | verified |
| TC-KEL012-01 | KEL-012 | unverifiable |
| TC-KEL013-01 | KEL-013 | verified |
| TC-KEL014-01 | KEL-014 | unverifiable |
| TC-KEL015-01 | KEL-015 | verified |
| TC-KEL016-01 | KEL-016 | unverifiable |
| TC-KEL017-01 | KEL-017 | unverifiable |
| TC-KEL018-01 | KEL-018 | verified |
| TC-KEL019-01 | KEL-019 | obsolete |
| TC-KEL020-01 | KEL-020 | obsolete |
| TC-KEL021-01 | KEL-021 | unverifiable |
| TC-KEL022-01 | KEL-022 | unverifiable |
| TC-KEL023-01 | KEL-023 | unverifiable |
| TC-KEL024-01 | KEL-024 | unverifiable |
| TC-KEL025-01 | KEL-025 | unverifiable |
| TC-KEL026-01 | KEL-026 | unverifiable |
| TC-KEL027-01 | KEL-027 | obsolete |
| TC-KEL028-01 | KEL-028 | obsolete |
| TC-KEL029-01 | KEL-029 | obsolete |
| TC-KEL030-01 | KEL-030 | unverifiable |
| TC-KEL032-01 | KEL-032 | obsolete |
| TC-KEL033-01 | KEL-033 | unverifiable |
| TC-KEL034-01 | KEL-034 | verified |
| TC-KEL035-01 | KEL-035 | unverifiable |
| TC-KEL036-01 | KEL-036 | unverifiable |
| TC-KEL038-01 | KEL-038 | verified |
| TC-KEL039-01 | KEL-039 | obsolete |
| TC-KEL041-01 | KEL-041 | unverifiable |
| TC-KEL042-01 | KEL-042 | obsolete |
| TC-KEL046-01 | KEL-046 | verified |
| TC-KEL049-01 | KEL-049 | verified |
| TC-KEL050-01 | KEL-050 | verified |
| TC-KEL051-01 | KEL-051 | unverifiable |
| TC-KEL061-01 | KEL-061 | obsolete |
| TC-KEL062-01 | KEL-062 | obsolete |
| TC-KEL063-01 | KEL-063 | obsolete |
| TC-KEL064-01 | KEL-064 | verified |
| TC-OB001-01 | OB-001 | unverifiable |
| TC-OB003-01 | OB-003 | verified |
| TC-SB020-01 | SB-020 | verified |
| TC-SB021-01 | SB-021 | verified |
| TC-SB023-01 | SB-023 | verified |
| TC-SB024-01 | SB-024 | verified |
| TC-SB032-01 | SB-032 | verified |
| TC-SB051-01 | SB-051 | unverifiable |
| TC-SB058-01 | SB-058 | regressed |
| TC-SB059-01 | SB-059 | verified |
| TC-SB060-01 | SB-060 | regressed |
| TC-SB069-01 | SB-069 | unverifiable |
| TC-SB070-01 | SB-070 | obsolete |
| TC-SB088-01 | SB-088 | obsolete |
| TC-SB089-01 | SB-089 | obsolete |
| TC-SB100-01 | SB-100 | verified |
| TC-SB126-01 | SB-126 | verified |
| TC-SB126-02 | SB-126 | verified |
| TC-SB129-01 | SB-129 | verified |
| TC-SB137-01 | SB-137 | verified |
| TC-SB142-01 | SB-142 | verified |
| TC-SB144-01 | SB-144 | verified |
| TC-SB145-01 | SB-145 | verified |
| TC-SB146-01 | SB-146 | verified |
| TC-SB147-01 | SB-147 | verified |
| TC-SB148-01 | SB-148 | verified |
| TC-SB149-01 | SB-149 | regressed |
| TC-SB150-01 | SB-150 | verified |
| TC-SB153-01 | SB-153 | regressed |
| TC-SB154-01 | SB-154 | verified |
| TC-SB156-01 | SB-156 | verified |
| TC-SB157-01 | SB-157 | verified |
| TC-SB170-01 | SB-170 | regressed |
| TC-SB171-01 | SB-171 | verified |
| TC-SB172-01 | SB-172 | verified |
| TC-SB174-01 | SB-174 | verified |
| TC-SB178-01 | SB-178 | verified |
| TC-SB179-01 | SB-179 | regressed |
| TC-SB189-01 | SB-189 | verified |
| TC-SB190-01 | SB-190 | verified |
| TC-SB191-01 | SB-191 | verified |
| TC-SB192-01 | SB-192 | verified |
| TC-SB193-01 | SB-193 | unverifiable |
| TC-SB194-01 | SB-194 | verified |
| TC-SB195-01 | SB-195 | regressed |
| TC-SB197-01 | SB-197 | verified |
| TC-SB198-01 | SB-198 | verified |
| TC-SB199-01 | SB-199 | verified |
| TC-SB200-01 | SB-200 | verified |
| TC-SB201-01 | SB-201 | verified |
| TC-SB209-01 | SB-209 | regressed |
| TC-SB212-01 | SB-212 | regressed |
| TC-SB214-01 | SB-214 | verified |
| TC-SB217-01 | SB-217 | regressed |
| TC-SB218-01 | SB-218 | obsolete |
| TC-SB220-01 | SB-220 | verified |
| TC-SB233-01 | SB-233 | verified |
| TC-SB240-01 | SB-240 | verified |
| TC-SB252-01 | SB-252 | verified |
| TC-SB255-01 | SB-255 | verified |
| TC-SB255-02 | SB-255 | verified |
| TC-SB256-01 | SB-256 | regressed |
| TC-SB257-01 | SB-257 | verified |
| TC-SB261-01 | SB-261 | verified |
| TC-SB264-01 | SB-264 | verified |
| TC-SB265-01 | SB-265 | verified |
| TC-SB266-01 | SB-266 | verified |
| TC-SB267-01 | SB-267 | verified |
| TC-SB268-01 | SB-268 | unverifiable |
| TC-SB269-01 | SB-269 | verified |
