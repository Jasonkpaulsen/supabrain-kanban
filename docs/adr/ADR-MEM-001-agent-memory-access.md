# ADR-MEM-001: Who can read an agent's memories

- **Status:** Accepted (System Architect, 2026-10-23), implementing Jason's SB-515 requirement of 2026-10-07
- **Tickets:** SB-581 (build), SB-515 (requirement)
- **Migration:** `supabase/migrations/20261023141914_sb581_agent_memory_access.sql`
- **Suite:** `supabase/tests/agent_memory_access_suite.sql` (TC-SB581-01 to TC-SB581-04)

## 1. Problem

Jason, SB-515: "Global memories should be available for all users that have access. Using an agent should include the agent memory."

The only SELECT policy on `public.memories`, `users_select_own`, let a signed-in user read:

- global rows;
- their own rows;
- project rows in a *shared* project they belong to.

An agent's memories are written in whatever project the agent was working in. So a user who can use the agent (through `agent_projects` and a project membership) could not read what the agent had learned elsewhere. `match_memories(p_agent => …)` also left out global memories, so an agent's recall needed two calls.

## 2. Decisions

| # | Question | Decision |
|---|----------|----------|
| D1 | Who reads an agent's memory | Every user `can_access_agent(agent_id, uid)` says can use the agent, whatever project the memory was written in. |
| D2 | Private memories | `scope = 'private'` stays owner-only, even with an `agent_id`. |
| D3 | Writes | Unchanged. Reading through an agent gives no update, insert or removal right. |
| D4 | Shape | One extra disjunct on `users_select_own`, not a second permissive policy. |
| D5 | Recall | `match_memories(p_agent)` returns the agent's rows plus global ones. |

## 3. Mechanism

`users_select_own` keeps its expression verbatim as the first part and gains:

```sql
OR (agent_id IS NOT NULL AND scope <> 'private'
    AND public.can_access_agent(agent_id, (select auth.uid())))
```

`can_access_agent` is SECURITY DEFINER. It refuses to answer for anyone but the caller, and checks for an `agent_projects` row whose project the user is a member of.

Why one policy (D4): a second permissive SELECT policy would add `memories` to the advisor's `multiple_permissive_policies` list. Postgres ORs permissive policies anyway, so one policy gives the same result.

`match_memories` keeps its signature, SECURITY INVOKER, `search_path = ''` and grants. Its agent filter becomes:

```sql
(p_agent IS NULL OR m.agent_id = p_agent OR m.scope = 'global')
```

RLS still decides which of those rows the caller sees.

The migration asserts against a snapshot taken before the change that:

- the old expression is kept;
- the other five policies are identical;
- `match_memories` is still invoker and has the new filter.

## 4. Exposure

The change is intentionally cross-project. A non-private agent memory is readable by every user of that agent.

Measured on 2026-10-23 over 236 memories (66 with an agent): **1** (user, memory) pair becomes newly readable. It is a Family Care Manager memory, readable by the one other user who can use that agent. TC-SB581-04 checks every such pair: non-private, with an agent the user can use, and not already readable.

## 5. Alternatives considered

- **A companion SELECT policy.** Same result, but adds a `multiple_permissive_policies` finding and a second place to reason about reads.
- **Agent memories visible only within the agent's linked projects.** This would not meet "using an agent should include the agent memory". Memories are written wherever the agent works, so most of them would stay hidden.
- **Include private agent memories.** Rejected. `private` means owner-only everywhere else, and an agent's private notes would leak to every user of the agent.
- **A SECURITY DEFINER recall RPC.** Moves the access rule out of RLS, so direct table reads and the RPC could disagree.
