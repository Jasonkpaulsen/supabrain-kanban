-- SB-465 follow-up, found by TC-SB453-V4 on the first QA run: four CRM tables
-- had no index leading with user_id, the column of their FK to auth.users.
--
-- Two reasons it matters. Deleting an account cascades through that FK, which
-- scans the table without an index. And every RLS policy on these tables filters
-- on user_id = auth.uid(), so an owner-scoped read had no index to start from.
-- The other eight owned tables already had one, through a composite key or a
-- lookup index; these four only had indexes that lead with a parent id.

create index crm_addresses_user            on public.crm_addresses (user_id);
create index crm_person_relationships_user on public.crm_person_relationships (user_id);
create index crm_group_members_user        on public.crm_group_members (user_id);
create index crm_entity_tags_user          on public.crm_entity_tags (user_id);

do $chk$
declare n int;
begin
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                       and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  if n <> 0 then raise exception 'A1: % CRM foreign keys still have no leading index', n; end if;
end $chk$;;
