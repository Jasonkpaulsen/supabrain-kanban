// Write-capable backend stub for batch 3 (SB-341).
//
// Batches 1-2 answer any non-GET with 405 because they are read-only. Batch 3
// mutates, so this module keeps an in-memory copy of the board and applies the
// same PostgREST calls the app makes, then serves the mutated state back on the
// next loadAll(). It also records every request so a test can assert on the
// exact wire call, not just the resulting pixels.
//
// WHAT THIS CANNOT DO: it is not Postgres. No trigger fires here — not the WIP
// limit, not the done gate, not the QA gate, not assignee_integrity. Cascade
// deletes are emulated by hand. So a green browser test proves the client sends
// the right request and renders the right result; it does NOT prove the
// database accepted it or reshaped it. The DB half of every batch-3 case is
// verified separately by SQL against the live project, and the two halves are
// recorded as such in test_runs.
const fs = require('fs');
const path = require('path');

const BASE = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'board-payload.json'), 'utf8')
);
const SUPABASE_UMD = require.resolve('@supabase/supabase-js/dist/umd/supabase.js');
const { SESSION } = require('./stub');

const clone = (o) => JSON.parse(JSON.stringify(o));
const idFromEq = (url, param) => {
  const m = new URL(url).searchParams.get(param);
  return m ? m.replace(/^eq\./, '') : null;
};

function createBackend(seed = BASE) {
  const state = {
    projects: clone(seed.projects),
    labels: clone(seed.labels),
    agents: clone(seed.agents),
    items: clone(seed.items),
    comments: [],
    labelLinks: [],
    requests: [],
  };

  // Seed label links from the payload's inline labels so edits can unlink them.
  state.items.forEach((it) => (it.labels || []).forEach((lb) =>
    state.labelLinks.push({ work_item_id: it.id, label_id: lb.id })));

  const relabel = (itemId) => {
    const it = state.items.find((i) => i.id === itemId);
    if (!it) return;
    it.labels = state.labelLinks
      .filter((l) => l.work_item_id === itemId)
      .map((l) => state.labels.find((x) => x.id === l.label_id))
      .filter(Boolean)
      .map((l) => ({ id: l.id, name: l.name, color: l.color }));
  };

  let created = 0;
  const newItem = (body) => {
    const project = state.projects.find((p) => p.id === body.project_id) || {};
    return Object.assign({
      id: `created-${++created}`, type: 'task', labels: [], archived: false,
      assignee: null, due_date: null, priority: 'medium', agent_icon: null,
      agent_name: null, sort_order: 0, ticket_code: null, acknowledged: false,
      comment_count: 0, assigned_agent_id: null, description: null,
      completed_at: null,
      project_icon: project.icon || null, project_name: project.name || null,
      project_domain: project.domain || null,
    }, body);
  };

  return { state, relabel, newItem };
}

async function installWriteStubs(page, seed) {
  const backend = createBackend(seed);
  // Live mode: batch 3 mutates, so it must NOT be pointed at the real project
  // by accident. Refuse loudly rather than writing to production data.
  if (process.env.E2E_LIVE === '1') {
    throw new Error(
      'installWriteStubs called with E2E_LIVE=1. Batch 3 performs writes and has ' +
      'no live-safe mode; run it against the stub, or seed a scratch project first.'
    );
  }
  const { state, relabel, newItem } = backend;

  const json = (route, body, status = 200) =>
    route.fulfill({
      status, contentType: 'application/json',
      headers: { 'access-control-allow-origin': '*' },
      body: JSON.stringify(body),
    });

  await page.route('**/cdn.jsdelivr.net/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD }));

  await page.route('**/auth/v1/**', (route) => {
    const url = route.request().url();
    if (url.includes('/token')) return json(route, SESSION);
    if (url.includes('/logout')) return route.fulfill({ status: 204, body: '' });
    if (url.includes('/user')) return json(route, SESSION.user);
    return json(route, {});
  });

  await page.route('**/rest/v1/**', async (route) => {
    const req = route.request();
    const url = req.url();
    const method = req.method();
    let body = null;
    try { body = req.postDataJSON(); } catch { /* no body */ }
    state.requests.push({ method, url, body });

    // ── RPC: move_work_item (drag-drop) ──
    if (url.includes('/rpc/move_work_item')) {
      const it = state.items.find((i) => i.id === body.p_item_id);
      if (!it) return json(route, { message: 'not found' }, 404);
      it.status = body.p_new_status;
      it.sort_order = body.p_new_sort_order;
      if (body.p_new_status === 'done') it.completed_at = new Date().toISOString();
      return json(route, null);
    }

    // ── work_items ──
    if (url.includes('/rest/v1/work_items')) {
      if (method === 'GET') {
        // PostgREST honours `id=eq.<uuid>`; returning the whole table here made
        // the stub a worse liar than the real API and broke a caller that reads
        // a single row back (SB-358).
        const id = idFromEq(url, 'id');
        return json(route, id ? state.items.filter((i) => i.id === id) : state.items);
      }
      if (method === 'POST') {
        const row = newItem(body);
        state.items.push(row);
        return json(route, [row], 201);
      }
      if (method === 'PATCH') {
        const id = idFromEq(url, 'id');
        const it = state.items.find((i) => i.id === id);
        if (!it) return json(route, { message: 'not found' }, 404);
        Object.assign(it, body);
        return json(route, [it]);
      }
      if (method === 'DELETE') {
        const id = idFromEq(url, 'id');
        state.items = state.items.filter((i) => i.id !== id);
        // Emulate the FK cascades so the UI sees what Postgres would leave.
        state.labelLinks = state.labelLinks.filter((l) => l.work_item_id !== id);
        state.comments = state.comments.filter((c) => c.work_item_id !== id);
        return route.fulfill({ status: 204, body: '' });
      }
    }

    // ── work_item_labels ──
    if (url.includes('/rest/v1/work_item_labels')) {
      if (method === 'DELETE') {
        const id = idFromEq(url, 'work_item_id');
        state.labelLinks = state.labelLinks.filter((l) => l.work_item_id !== id);
        relabel(id);
        return route.fulfill({ status: 204, body: '' });
      }
      if (method === 'POST') {
        const rows = Array.isArray(body) ? body : [body];
        rows.forEach((r) => state.labelLinks.push(r));
        if (rows.length) relabel(rows[0].work_item_id);
        return json(route, rows, 201);
      }
    }

    // ── work_item_comments ──
    if (url.includes('/rest/v1/work_item_comments')) {
      if (method === 'GET') {
        const id = idFromEq(url, 'work_item_id');
        const rows = state.comments
          .filter((c) => c.work_item_id === id)
          .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
        return json(route, rows);
      }
      if (method === 'POST') {
        const row = Object.assign(
          { id: `comment-${state.comments.length + 1}`, created_at: new Date().toISOString() },
          body);
        state.comments.push(row);
        const it = state.items.find((i) => i.id === row.work_item_id);
        if (it) it.comment_count = (it.comment_count || 0) + 1;
        return json(route, [row], 201);
      }
    }

    // ── read paths ──
    if (url.includes('/rest/v1/projects')) return json(route, state.projects);
    if (url.includes('/rest/v1/labels')) return json(route, state.labels);
    if (url.includes('/rest/v1/agents')) return json(route, state.agents);
    if (url.includes('/rest/v1/kanban_board_view')) return json(route, state.items);
    return json(route, []);
  });

  return backend;
}

// Requests matching a method + path fragment, newest last.
const requestsFor = (backend, method, fragment) =>
  backend.state.requests.filter((r) => r.method === method && r.url.includes(fragment));

module.exports = { installWriteStubs, requestsFor, BASE };
