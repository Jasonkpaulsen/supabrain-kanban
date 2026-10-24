-- SB-479: lock down public.meta_key_registry and audit_meta_keys(integer).
--
-- Finding (System Architect, 2026-09-20; advisor lint 0013 rls_disabled_in_public):
-- the registry sat in the PostgREST-exposed public schema with RLS disabled, no
-- policies, and the Supabase default table grants -- anon and authenticated each
-- held SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER. The
-- table holds no credentials or personal data, but it is governance metadata that
-- two WIP gates and archive_work_items read through (wip_override,
-- archive_after_days), so an unauthenticated write could mislead governance.
--
-- Access contract, from the ticket's default recommendation, with the one open
-- question settled by evidence rather than assumption:
--   postgres (owner) and service_role : read/write. The owner bypasses RLS as owner
--                                       (FORCE ROW LEVEL SECURITY is not set) and
--                                       service_role carries BYPASSRLS, so no
--                                       policy is needed for either.
--   anon                              : nothing. No table privilege, no EXECUTE.
--   authenticated                     : nothing. pg_stat_statements holds no call
--                                       to the table or to audit_meta_keys by
--                                       anon or authenticated since the table was
--                                       created on 2026-08-31; the only callers
--                                       have been postgres (the migration, backups,
--                                       one manual audit). There is no first-party
--                                       client to preserve, so the read path is
--                                       removed rather than retained on speculation.
-- Zero policies is therefore the minimum policy set the contract requires, and the
-- ticket's instruction not to add a blanket TO authenticated policy is honoured.
--
-- audit_meta_keys is SECURITY INVOKER and reads the registry as the caller, so its
-- EXECUTE grant must match the table contract or it is a hole in it. The 20260831
-- migration granted it to authenticated and service_role but left the default
-- PUBLIC grant in place, which is why anon could call it.
--
-- Rollback (restores the pre-change state exactly; not recommended):
--   alter table public.meta_key_registry disable row level security;
--   grant all privileges on table public.meta_key_registry to anon, authenticated;
--   grant execute on function public.audit_meta_keys(integer) to public, anon, authenticated;
--
-- The DO block at the end asserts every acceptance criterion the database can
-- check and raises if any fails, so this migration cannot half-apply and record.

alter table public.meta_key_registry enable row level security;

revoke all privileges on table public.meta_key_registry from public, anon, authenticated;

revoke execute on function public.audit_meta_keys(integer) from public, anon, authenticated;
grant execute on function public.audit_meta_keys(integer) to service_role;

do $$
declare
  v_rows int;
  v_priv text;
  v_role text;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.meta_key_registry'::regclass) then
    raise exception 'SB-479: RLS is not enabled on meta_key_registry';
  end if;

  foreach v_role in array array['anon','authenticated'] loop
    foreach v_priv in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege(v_role, 'public.meta_key_registry', v_priv) then
        raise exception 'SB-479: % still holds % on meta_key_registry', v_role, v_priv;
      end if;
    end loop;
    if has_function_privilege(v_role, 'public.audit_meta_keys(integer)', 'EXECUTE') then
      raise exception 'SB-479: % can still execute audit_meta_keys', v_role;
    end if;
  end loop;

  if not has_function_privilege('service_role', 'public.audit_meta_keys(integer)', 'EXECUTE') then
    raise exception 'SB-479: service_role lost EXECUTE on audit_meta_keys';
  end if;
  if not has_table_privilege('service_role', 'public.meta_key_registry', 'SELECT') then
    raise exception 'SB-479: service_role lost SELECT on meta_key_registry';
  end if;

  select count(*) into v_rows from public.meta_key_registry;
  if v_rows <> 12 then
    raise exception 'SB-479: expected 12 registry rows, found %', v_rows;
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.meta_key_registry'::regclass
                    and contype = 'u'
                    and pg_get_constraintdef(oid) = 'UNIQUE (table_name, key_name)') then
    raise exception 'SB-479: unique (table_name, key_name) constraint is missing';
  end if;

  raise notice 'SB-479: registry locked down; % rows intact', v_rows;
end $$;
