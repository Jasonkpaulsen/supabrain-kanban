// Bulk board payload for TC-SB118 (render performance + edge cases).
//
// The bulk variant is really seeded — project "QA Fixture Bulk"
// (5fe2d8a4-7801-435b-9614-4745f95ea8aa) holds 525 rows under the QA fixture
// user, in its own project so it cannot perturb the baseline counts batch 1
// asserts on.
//
// The four edge-case rows and the catch-all epic below are copied verbatim from
// kanban_board_view. The remaining 520 are synthesised here rather than dumped,
// because a 525-row dump is unwieldy to keep in the repo — but the synthetic
// rows reproduce the seeded distribution exactly:
//
//   backlog 159 | todo 105 | in_progress 31 | on_hold 73
//   blocked  52 | review 53 | done 52                      = 525
//   agent_name IS NULL                                     = 176
//
// Those totals are the post-trigger reality, not what the seed asked for: 52
// rows were inserted as in_progress but enforce_wip_limit silently redirected
// 21 of them to on_hold once assignee_integrity derived an assignee from
// assigned_agent_id. The fixture keeps the redirected shape because that is
// what the board actually has to render.
const PROJECT_ID = '5fe2d8a4-7801-435b-9614-4745f95ea8aa';
const EPIC_ID = 'fc52b55c-e584-4511-b3f0-a3725db7a83f';

const BULK_TOTALS = {
  total: 525,
  byStatus: { backlog: 159, todo: 105, in_progress: 31, on_hold: 73, blocked: 52, review: 53, done: 52, escalated: 0 },
  unassigned: 176,
};

const PROJECT = {
  id: PROJECT_ID, name: 'QA Fixture Bulk', icon: '📦',
  domain: 'operations', archived: false, meta: { qa_fixture: true, bulk_variant: true },
};

const LICENSE_LABEL = { id: 'aacb3279-056f-4432-9fe8-7fe4e32c36c3', name: 'license-check', color: '#f778ba' };

const base = (over) => Object.assign({
  type: 'task', labels: [], archived: false, assignee: null, due_date: null,
  priority: 'medium', agent_icon: null, agent_name: null, project_id: PROJECT_ID,
  ticket_code: null, acknowledged: false, project_icon: '📦',
  project_name: 'QA Fixture Bulk', comment_count: 0, project_domain: 'operations',
  assigned_agent_id: null, description: null,
}, over);

// Verbatim from the view — these carry the conditions TC-18 steps 5-8 name.
const EDGE = {
  longTitle: base({
    id: '17279e94-e267-4169-a193-f8065defab3b', sort_order: 9001, status: 'backlog',
    title: 'Bulk edge — very long title ' + 'that must wrap gracefully rather than overflow its card box '.repeat(4),
    description: 'TC-18 step 5: title exceeds 200 characters.',
    assignee: 'SupaBrain QA', agent_name: 'SupaBrain QA', agent_icon: '🔍',
    assigned_agent_id: '9a5eb78f-4365-4929-a3d7-d7983a5983c9', due_date: '2026-08-22',
  }),
  bare: base({
    id: 'd6cd4ed3-d39f-4f41-a326-2d6516f76464', sort_order: 9002, status: 'todo',
    title: 'Bulk edge — bare item',
  }),
  complianceTitle: base({
    id: 'fd797937-f8fb-4936-a254-bc411a7ebbf6', sort_order: 9003, status: 'review',
    title: 'Bulk edge — compliance sign-off required',
    description: 'Title carries the compliance keyword.', priority: 'high',
    assignee: 'SupaBrain QA', agent_name: 'SupaBrain QA', agent_icon: '🔍',
    assigned_agent_id: '9a5eb78f-4365-4929-a3d7-d7983a5983c9',
  }),
  complianceLabel: base({
    id: '425a1f7b-889f-4053-97c6-485c957313d3', sort_order: 9004, status: 'backlog',
    title: 'Bulk edge — neutral title with flagged label',
    description: 'Title is clean; the label is what should trip the badge.',
    priority: 'low', labels: [LICENSE_LABEL],
  }),
  epic: base({
    id: EPIC_ID, sort_order: 9999, status: 'backlog', type: 'epic',
    title: 'Catch-All — Unsorted', priority: 'low',
  }),
};

// The five verbatim rows already cover part of the distribution; the synthetic
// rows make up the remainder so the totals above hold exactly.
const SYNTHETIC = {
  backlog: 159 - 3, todo: 105 - 1, in_progress: 31, on_hold: 73,
  blocked: 52, review: 53 - 1, done: 52,
};
const VERBATIM_UNASSIGNED = 3; // bare, complianceLabel, epic

function buildBulkItems(agents) {
  const items = Object.values(EDGE);
  const statuses = [];
  Object.keys(SYNTHETIC).forEach((s) => { for (let i = 0; i < SYNTHETIC[s]; i++) statuses.push(s); });

  const withAgent = statuses.length - (BULK_TOTALS.unassigned - VERBATIM_UNASSIGNED);
  statuses.forEach((status, i) => {
    const agent = i < withAgent ? agents[i % agents.length] : null;
    items.push(base({
      id: `bulk-${String(i + 1).padStart(4, '0')}`,
      title: `Bulk fixture item ${String(i + 1).padStart(3, '0')}`,
      description: i % 4 === 0 ? null : `Synthetic bulk row ${i + 1} for TC-18 render timing.`,
      status,
      priority: ['low', 'medium', 'medium', 'high', 'critical'][i % 5],
      sort_order: i + 1,
      assignee: agent ? agent.name : null,
      agent_name: agent ? agent.name : null,
      agent_icon: agent ? agent.icon : null,
      assigned_agent_id: agent ? agent.id : null,
      due_date: i % 7 === 0 ? '2026-07-20' : i % 7 === 3 ? '2026-09-20' : null,
    }));
  });
  return items;
}

// Baseline payload + the bulk project, as the board sees it in one load.
function withBulk(payload) {
  const items = buildBulkItems(payload.agents);
  return {
    projects: payload.projects.concat([PROJECT]),
    labels: payload.labels.concat([LICENSE_LABEL]),
    agents: payload.agents,
    items: payload.items.concat(items),
  };
}

module.exports = { withBulk, BULK_TOTALS, PROJECT, EDGE, LICENSE_LABEL, PROJECT_ID };
