-- SB-624: projects.domain must be chosen, not defaulted.
--
-- The column was added (20260604015042) with DEFAULT 'professional'. The check was
-- widened twice since and 'professional' was never carried over, so every insert that
-- relied on the default has failed with 23514 since 2026-06-10. domain is a privacy scope
-- boundary, so a replacement guess could file a project on the wrong side of it; the
-- default is removed instead. An insert without domain now fails with 23502 on domain,
-- which names the real problem. No row changes.
alter table public.projects alter column domain drop default;

comment on column public.projects.domain is
  'Scope boundary, required (no default since SB-624): products, business, career, property, operations, family, hobbies, club, prediction-markets (projects_domain_check). Agents and queries respect it unless explicitly asked to cross it.';

do $assert$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'projects' and column_name = 'domain'
                and (column_default is not null or is_nullable <> 'NO')) then
    raise exception 'SB-624: projects.domain still has a default or is nullable';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint
       where conrelid = 'public.projects'::regclass and conname = 'projects_domain_check')
     is distinct from 'CHECK ((domain = ANY (ARRAY[''products''::text, ''business''::text, ''career''::text, ''property''::text, ''operations''::text, ''family''::text, ''hobbies''::text, ''club''::text, ''prediction-markets''::text])))' then
    raise exception 'SB-624: projects_domain_check changed';
  end if;
end
$assert$;
