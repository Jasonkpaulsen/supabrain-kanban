-- SB-372: the ecosystem records design->implementation handoffs in
-- work_item_links (blocks/blocked_by), but the Management Agent Sweep's
-- Enhancement B detector reads meta.upstream_ticket. The two conventions were
-- almost entirely disjoint -- of 172 handoff pairs in work_item_links, exactly
-- ONE carried the field -- so the detector reported nearly every completed
-- Architect ticket as a stalled handoff. That noise produced SB-181, SB-289,
-- SB-290, SB-304 and SB-347 (all since closed as meta-tickets) and the 26
-- false positives reported by SB-365.
--
-- SB-372 offered two remedies: teach the detector about work_item_links, or
-- populate meta.upstream_ticket on handoff. The detector lives in an agent
-- skill file outside this database; the data does not. This takes the second
-- remedy, which also leaves the detector untouched and therefore cannot break it.
--
-- work_item_links stays the source of truth. meta.upstream_ticket is a derived
-- convenience for the detector, and it is a SCALAR: 27 of the 122 downstream
-- items have more than one upstream (up to 8), so the field names the first
-- link seen and cannot represent the rest. First link wins, deterministically;
-- an existing value is never overwritten.
CREATE OR REPLACE FUNCTION public.sync_upstream_ticket_from_link()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_up_id   uuid;
  v_down_id uuid;
  v_up_code text;
BEGIN
  -- 'A blocks B'     => A is upstream of B
  -- 'A blocked_by B' => B is upstream of A
  IF NEW.link_type = 'blocks' THEN
    v_up_id := NEW.from_item_id; v_down_id := NEW.to_item_id;
  ELSIF NEW.link_type = 'blocked_by' THEN
    v_up_id := NEW.to_item_id;   v_down_id := NEW.from_item_id;
  ELSE
    RETURN NULL;  -- relates_to is not a handoff
  END IF;

  SELECT ticket_code INTO v_up_code FROM work_items WHERE id = v_up_id;
  IF v_up_code IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    UPDATE work_items
       SET meta = COALESCE(meta,'{}'::jsonb) || jsonb_build_object(
             'upstream_ticket', v_up_code,
             'upstream_ticket_source', 'SB-372 trigger sync_upstream_ticket_from_link')
     WHERE id = v_down_id
       AND NOT (COALESCE(meta,'{}'::jsonb) ? 'upstream_ticket');
  EXCEPTION WHEN OTHERS THEN
    -- Same posture as enforce_wip_limit and log_assignee_change: a derived
    -- convenience field must never block the link it only describes.
    RAISE WARNING 'sync_upstream_ticket_from_link: update failed: %', SQLERRM;
  END;

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_upstream_ticket ON public.work_item_links;
CREATE TRIGGER trg_sync_upstream_ticket
  AFTER INSERT ON public.work_item_links
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_upstream_ticket_from_link();

COMMENT ON FUNCTION public.sync_upstream_ticket_from_link() IS
'SB-372: mirrors a blocks/blocked_by handoff into the downstream item''s meta.upstream_ticket, so the Management Agent Sweep Enhancement B detector (which reads that field) agrees with work_item_links (which the ecosystem actually uses). Fires on link INSERT only; first link wins and an existing value is never overwritten. work_item_links remains the source of truth -- the field is a scalar and cannot represent multiple upstreams.';;
