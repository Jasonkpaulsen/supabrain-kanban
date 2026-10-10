-- SB-477 follow-up: every CRM foreign key is backed by an index that leads with all
-- of its columns (the catalog.fk_indexed rule in the CRM suites). The composite
-- (id, user_id) keys added by sb477_crm_import_contract were indexed on the first
-- column only. These cover them; the single-column indexes become redundant and can
-- go in a later cleanup.

create index crm_external_ids_person_owner on public.crm_external_ids (person_id, user_id) where person_id is not null;
create index crm_external_ids_interaction_owner on public.crm_external_ids (interaction_id, user_id) where interaction_id is not null;
create index crm_import_conflicts_batch_owner on public.crm_import_conflicts (batch_id, user_id);

do $chk$
declare n int;
begin
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index x where x.indrelid = c.conrelid
                       and (x.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  if n > 0 then raise exception 'A1: % CRM foreign key(s) without a covering index', n; end if;
end $chk$;
