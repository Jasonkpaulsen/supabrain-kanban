
-- SB-394: the boards read this view, so the hold columns have to reach it or the
-- badge has nothing to render. Appended at the end — column order is part of the
-- view's contract for CREATE OR REPLACE.
create or replace view public.kanban_board_view as
 SELECT w.id, w.project_id, w.user_id, w.ticket_code, w.title, w.description,
    w.type, w.status, w.priority, w.sort_order, w.assignee, w.due_date,
    w.source_table, w.source_id, w.created_at, w.updated_at, w.completed_at,
    w.assigned_agent_id, w.approved_by, w.approved_at, w.approval_status,
    w.parent_id, w.acknowledged, w.acknowledged_at, w.snoozed_until,
    parent.title AS parent_title,
    p.name AS project_name, p.icon AS project_icon, p.project_key,
    p.domain AS project_domain,
    a.name AS agent_name, a.icon AS agent_icon, a.status AS agent_status,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
           FROM work_item_labels wl JOIN labels l ON l.id = wl.label_id
          WHERE wl.work_item_id = w.id), '[]'::jsonb) AS labels,
    ( SELECT count(*) FROM work_item_comments c WHERE c.work_item_id = w.id) AS comment_count,
    ( SELECT count(*) FROM work_items child WHERE child.parent_id = w.id) AS child_count,
    ( SELECT count(*) FROM work_items child
       WHERE child.parent_id = w.id AND child.status = 'done'::text) AS completed_child_count,
    ( SELECT count(*) FROM work_item_links wil
        JOIN work_items blocker ON blocker.id = wil.from_item_id
       WHERE wil.to_item_id = w.id AND wil.link_type = 'blocks'::text
         AND blocker.status <> 'done'::text) AS blocked_by_count,
    w.archived, w.archived_at,
    w.hold_reason,
    w.held_by_gate
   FROM work_items w
     JOIN projects p ON p.id = w.project_id
     LEFT JOIN agents a ON a.id = w.assigned_agent_id
     LEFT JOIN work_items parent ON parent.id = w.parent_id;
;
