-- SB-633 (verifier, 2026-10-25): image_assets.status is never null.
--
-- The removal rules keep saved and library images out of an article's purge. The client filters
-- with status NOT IN ('saved','library'), which in SQL also drops rows whose status is null, while
-- lce-cleanup's in-memory check treats null as removable, so the two paths disagreed on a null row.
-- The column already defaults to 'library' and holds no nulls (0 on 2026-10-25), so it becomes
-- NOT NULL and both paths see the same set.

alter table public.image_assets alter column status set not null;

do $assert$
begin
  if not (select attnotnull from pg_attribute where attrelid = 'public.image_assets'::regclass and attname = 'status') then
    raise exception 'SB-633: image_assets.status is still nullable';
  end if;
  if (select pg_get_expr(adbin, adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
       where d.adrelid = 'public.image_assets'::regclass and a.attname = 'status') is distinct from '''library''::text' then
    raise exception 'SB-633: image_assets.status default changed';
  end if;
end
$assert$;