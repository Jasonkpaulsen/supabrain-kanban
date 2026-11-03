
-- SB-396: a detector that reads a field must know how widely that field is adopted
-- before it escalates on the field's absence.
--
-- Enhancement B escalated when a completed Architect ticket had no downstream ticket
-- carrying meta.upstream_ticket. That key is present on 143 of 502 live work items, so
-- the rule fired on the convention's rollout, not on missed handoffs: 5 escalations and
-- 26 false positives, plus SB-374 reporting 32 more.
--
-- This is the check it should have made first. It is deliberately a REPORTING function,
-- not a gate that blocks: per this ticket, report before escalating.
create or replace function public.detector_field_adoption(
  p_table text,
  p_expression text,
  p_min_rate numeric default 0.60
)
returns table (
  measured_rows bigint,
  populated_rows bigint,
  adoption_rate numeric,
  meets_threshold boolean,
  verdict text
)
language plpgsql
stable
set search_path to 'public'
as $fn$
declare v_total bigint; v_pop bigint;
begin
  if p_table !~ '^[a-z_][a-z0-9_]*$' then
    raise exception 'detector_field_adoption: unsafe table name %', p_table;
  end if;
  execute format('select count(*), count(*) filter (where %s) from public.%I', p_expression, p_table)
    into v_total, v_pop;

  measured_rows  := v_total;
  populated_rows := v_pop;
  adoption_rate  := case when v_total = 0 then 0 else round(v_pop::numeric / v_total, 3) end;
  meets_threshold := adoption_rate >= p_min_rate;
  verdict := case
    when v_total = 0 then 'no rows measured — detector must no-op'
    when meets_threshold then format('adoption %s%% — detector may escalate', round(adoption_rate*100))
    else format('adoption %s%% is below the %s%% threshold — detector must report the shortfall, NOT escalate on absence',
                round(adoption_rate*100), round(p_min_rate*100))
  end;
  return next;
end;
$fn$;

comment on function public.detector_field_adoption(text,text,numeric) is
  'SB-396: measure how widely a field is populated before a detector escalates on its absence. A rule whose trigger condition is "field is missing" measures its own rollout until adoption is high.';

grant execute on function public.detector_field_adoption(text,text,numeric) to authenticated, service_role;
;
