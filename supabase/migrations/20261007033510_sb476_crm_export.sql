-- SB-476 (ADR-CRM-005 §4): user-controlled structured export.
--
-- crm_export(reason, include_restricted, include_archived) returns the owner's whole
-- CRM as one versioned document, crm.export.v1: people with their contact points,
-- addresses, important dates, facts, tags and groups nested; organizations (with
-- tags), affiliations, relationships (with type code and label), interactions (with
-- participants), follow-up actions, and the group and tag lists. Every row keeps its
-- id and provenance columns; only user_id and derived search columns are left out.
--
-- Explicit and audited: a reason code is required, one `export` audit row is written
-- before anything is returned, and including restricted data writes a further
-- `restricted_read` row. Restricted (sensitive / highly_sensitive) facts, interactions
-- and actions, and archived rows (merged people included), are left out unless asked
-- for, and counted under `omitted`. SECURITY INVOKER with an explicit owner filter; no
-- user session is an error, never an empty "success". Not an agent surface.

create function public.crm_export(
  p_reason             text,
  p_include_restricted boolean default false,
  p_include_archived   boolean default false
) returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  r        boolean := coalesce(p_include_restricted, false);
  a        boolean := coalesce(p_include_archived, false);
  v_people int;
  v_rf     int;
  v_ri     int;
  v_ra     int;
  v_arch   int;
  v_doc    jsonb;
begin
  if v_uid is null then
    raise exception 'CRM export needs a signed-in owner' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'CRM export needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;

  select count(*) into v_people from public.crm_people p where p.user_id = v_uid and (a or not p.archived);
  if v_people > 25000 then
    raise exception 'CRM export is limited to 25000 people (owner has %)', v_people using errcode = '54000';
  end if;
  select count(*) into v_arch from public.crm_people p where p.user_id = v_uid and p.archived and not a;

  -- Restricted rows that belong to exported records (counted either way: omitted, or
  -- included and audited as a restricted read).
  select count(*) into v_rf from public.crm_facts f
    join public.crm_people p on p.id = f.person_id and p.user_id = v_uid and (a or not p.archived)
   where f.user_id = v_uid and (a or not f.archived) and f.sensitivity in ('sensitive','highly_sensitive');
  select count(*) into v_ri from public.crm_interactions i
   where i.user_id = v_uid and (a or not i.archived) and i.sensitivity in ('sensitive','highly_sensitive');
  select count(*) into v_ra from public.crm_actions x
   where x.user_id = v_uid and (a or not x.archived) and x.sensitivity in ('sensitive','highly_sensitive');

  -- Audit before data: if either insert fails, nothing is returned.
  perform public.crm_audit('export', 'crm_people', null, v_people, 'succeeded', p_reason, null, v_uid);
  if r and v_rf + v_ri + v_ra > 0 then
    perform public.crm_audit('restricted_read', 'crm_people', null, v_rf + v_ri + v_ra, 'succeeded', p_reason, null, v_uid);
  end if;

  with
  ppl as (
    select p.* from public.crm_people p where p.user_id = v_uid and (a or not p.archived)
  ),
  cps as (
    select c.person_id, jsonb_agg(to_jsonb(c) - 'user_id' - 'value_normalized' order by c.kind, c.created_at, c.id) j, count(*) n
      from public.crm_contact_points c join ppl on ppl.id = c.person_id
     where c.user_id = v_uid and (a or not c.archived)
     group by c.person_id
  ),
  adr as (
    select d.person_id, jsonb_agg(to_jsonb(d) - 'user_id' order by d.created_at, d.id) j, count(*) n
      from public.crm_addresses d join ppl on ppl.id = d.person_id
     where d.user_id = v_uid and (a or not d.archived)
     group by d.person_id
  ),
  dts as (
    select d.person_id, jsonb_agg(to_jsonb(d) - 'user_id' order by d.month, d.day, d.id) j, count(*) n
      from public.crm_important_dates d join ppl on ppl.id = d.person_id
     where d.user_id = v_uid and (a or not d.archived)
     group by d.person_id
  ),
  fct as (
    select f.person_id, jsonb_agg(to_jsonb(f) - 'user_id' - 'search_tsv' order by f.created_at, f.id) j, count(*) n
      from public.crm_facts f join ppl on ppl.id = f.person_id
     where f.user_id = v_uid and (a or not f.archived) and (r or f.sensitivity in ('normal','private'))
     group by f.person_id
  ),
  ptg as (
    select e.person_id, jsonb_agg(jsonb_build_object('tag_id', t.id, 'name', t.name) order by t.name, t.id) j, count(*) n
      from public.crm_entity_tags e
      join ppl on ppl.id = e.person_id
      join public.crm_tags t on t.id = e.tag_id and t.user_id = v_uid
     where e.user_id = v_uid and (a or (not e.archived and not t.archived))
     group by e.person_id
  ),
  pgr as (
    select m.person_id, jsonb_agg(jsonb_build_object('group_id', g.id, 'name', g.name, 'role', m.role) order by g.name, g.id) j, count(*) n
      from public.crm_group_members m
      join ppl on ppl.id = m.person_id
      join public.crm_groups g on g.id = m.group_id and g.user_id = v_uid
     where m.user_id = v_uid and (a or (not m.archived and not g.archived))
     group by m.person_id
  ),
  people_j as (
    select coalesce(jsonb_agg((to_jsonb(p) - 'user_id' - 'name_normalized') || jsonb_build_object(
             'contact_points',  coalesce(cps.j, '[]'::jsonb),
             'addresses',       coalesce(adr.j, '[]'::jsonb),
             'important_dates', coalesce(dts.j, '[]'::jsonb),
             'facts',           coalesce(fct.j, '[]'::jsonb),
             'tags',            coalesce(ptg.j, '[]'::jsonb),
             'groups',          coalesce(pgr.j, '[]'::jsonb))
           order by p.display_name, p.id), '[]'::jsonb) j,
           count(*) n, coalesce(sum(cps.n), 0) n_cp, coalesce(sum(adr.n), 0) n_adr, coalesce(sum(dts.n), 0) n_dt,
           coalesce(sum(fct.n), 0) n_f
      from ppl p
      left join cps on cps.person_id = p.id
      left join adr on adr.person_id = p.id
      left join dts on dts.person_id = p.id
      left join fct on fct.person_id = p.id
      left join ptg on ptg.person_id = p.id
      left join pgr on pgr.person_id = p.id
  ),
  org as (
    select o.* from public.crm_organizations o where o.user_id = v_uid and (a or not o.archived)
  ),
  otg as (
    select e.organization_id, jsonb_agg(jsonb_build_object('tag_id', t.id, 'name', t.name) order by t.name, t.id) j
      from public.crm_entity_tags e
      join org on org.id = e.organization_id
      join public.crm_tags t on t.id = e.tag_id and t.user_id = v_uid
     where e.user_id = v_uid and (a or (not e.archived and not t.archived))
     group by e.organization_id
  ),
  org_j as (
    select coalesce(jsonb_agg((to_jsonb(o) - 'user_id' - 'name_normalized') || jsonb_build_object('tags', coalesce(otg.j, '[]'::jsonb))
           order by o.name, o.id), '[]'::jsonb) j, count(*) n
      from org o left join otg on otg.organization_id = o.id
  ),
  aff_j as (
    select coalesce(jsonb_agg(to_jsonb(x) - 'user_id' order by x.created_at, x.id), '[]'::jsonb) j, count(*) n
      from public.crm_affiliations x
      join ppl on ppl.id = x.person_id
      join org on org.id = x.organization_id
     where x.user_id = v_uid and (a or not x.archived)
  ),
  rel_j as (
    select coalesce(jsonb_agg((to_jsonb(x) - 'user_id') || jsonb_build_object('type_code', t.code, 'type_label', t.label)
           order by x.created_at, x.id), '[]'::jsonb) j, count(*) n
      from public.crm_person_relationships x
      join ppl p1 on p1.id = x.person_id
      join ppl p2 on p2.id = x.related_person_id
      join public.crm_relationship_types t on t.id = x.relationship_type_id
     where x.user_id = v_uid and (a or not x.archived)
  ),
  itx as (
    select i.* from public.crm_interactions i
     where i.user_id = v_uid and (a or not i.archived) and (r or i.sensitivity in ('normal','private'))
  ),
  prt as (
    select ip.interaction_id, jsonb_agg(to_jsonb(ip) - 'user_id' order by ip.created_at, ip.id) j, count(*) n
      from public.crm_interaction_participants ip
      join itx on itx.id = ip.interaction_id
      left join ppl on ppl.id = ip.person_id
      left join org on org.id = ip.organization_id
     where ip.user_id = v_uid and (a or not ip.archived)
       and (ip.person_id is null or ppl.id is not null)
       and (ip.organization_id is null or org.id is not null)
     group by ip.interaction_id
  ),
  itx_j as (
    select coalesce(jsonb_agg((to_jsonb(i) - 'user_id' - 'search_tsv') || jsonb_build_object('participants', coalesce(prt.j, '[]'::jsonb))
           order by i.occurred_at, i.id), '[]'::jsonb) j, count(*) n, coalesce(sum(prt.n), 0) n_p
      from itx i left join prt on prt.interaction_id = i.id
  ),
  act_j as (
    select coalesce(jsonb_agg(to_jsonb(x) - 'user_id' order by x.created_at, x.id), '[]'::jsonb) j, count(*) n
      from public.crm_actions x
     where x.user_id = v_uid and (a or not x.archived) and (r or x.sensitivity in ('normal','private'))
       and (x.person_id is null or exists (select 1 from ppl where ppl.id = x.person_id))
       and (x.organization_id is null or exists (select 1 from org where org.id = x.organization_id))
       and (x.interaction_id is null or exists (select 1 from itx where itx.id = x.interaction_id))
  ),
  grp_j as (
    select coalesce(jsonb_agg(to_jsonb(g) - 'user_id' order by g.name, g.id), '[]'::jsonb) j, count(*) n
      from public.crm_groups g where g.user_id = v_uid and (a or not g.archived)
  ),
  tag_j as (
    select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.name, t.id), '[]'::jsonb) j, count(*) n
      from public.crm_tags t where t.user_id = v_uid and (a or not t.archived)
  )
  select jsonb_build_object(
           'format', 'crm.export.v1',
           'exported_at', now(),
           'include_restricted', r,
           'include_archived', a,
           'counts', jsonb_build_object(
              'people', pj.n, 'contact_points', pj.n_cp, 'addresses', pj.n_adr, 'important_dates', pj.n_dt,
              'facts', pj.n_f, 'organizations', oj.n, 'affiliations', aj.n, 'relationships', rj.n,
              'interactions', ij.n, 'participants', ij.n_p, 'actions', xj.n, 'groups', gj.n, 'tags', tj.n),
           'omitted', jsonb_build_object(
              'restricted_facts',        case when r then 0 else v_rf end,
              'restricted_interactions', case when r then 0 else v_ri end,
              'restricted_actions',      case when r then 0 else v_ra end,
              'archived_people',         v_arch),
           'people', pj.j, 'organizations', oj.j, 'affiliations', aj.j, 'relationships', rj.j,
           'interactions', ij.j, 'actions', xj.j, 'groups', gj.j, 'tags', tj.j)
    into v_doc
    from people_j pj, org_j oj, aff_j aj, rel_j rj, itx_j ij, act_j xj, grp_j gj, tag_j tj;

  return v_doc;
end $fn$;

revoke all on function public.crm_export(text, boolean, boolean) from public, anon;
grant execute on function public.crm_export(text, boolean, boolean) to authenticated, service_role;

do $chk$
begin
  -- A1: caller's rights; authenticated can run it, anon cannot
  if (select prosecdef from pg_proc where oid = 'public.crm_export(text,boolean,boolean)'::regprocedure)
     or not has_function_privilege('authenticated', 'public.crm_export(text,boolean,boolean)', 'execute')
     or has_function_privilege('anon', 'public.crm_export(text,boolean,boolean)', 'execute') then
    raise exception 'A1: crm_export must be invoker, executable by authenticated and not by anon';
  end if;
  -- A2: it writes the audit, so it must not be STABLE or IMMUTABLE
  if (select provolatile from pg_proc where oid = 'public.crm_export(text,boolean,boolean)'::regprocedure) <> 'v' then
    raise exception 'A2: crm_export must be VOLATILE (it writes the export audit row)';
  end if;
  -- A3: export is not an agent surface (ADR-CRM-004 §2.1 set unchanged)
  if (select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'public' and p.proname like 'crm\_%\_for\_agent')
     <> array['crm_facts_for_agent','crm_interactions_for_agent','crm_person_card_for_agent']::name[] then
    raise exception 'A3: the *_for_agent set changed';
  end if;
  -- A4: export is an action crm_audit accepts from callers
  if not exists (select 1 from pg_proc where oid = 'public.crm_audit(text,text,uuid,integer,text,text,text,uuid)'::regprocedure
                  and prosrc like '%''export''%') then
    raise exception 'A4: crm_audit does not accept export';
  end if;
end $chk$;
