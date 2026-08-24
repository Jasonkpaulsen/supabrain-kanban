// Network stub for the board's backend.
//
// This runner has no egress to supabase.co or cdn.jsdelivr.net (the org proxy
// answers 403 to CONNECT for both), so the suite serves the vendored
// supabase-js bundle and replays REST payloads captured from the seeded
// fixture instead of calling the live API.
//
// The payloads in fixtures/board-payload.json are a verbatim dump of what the
// QA fixture user sees through kanban_board_view under RLS — the rendering
// path under test is unchanged; only the transport is replaced. Anything that
// genuinely needs the live round trip (session sharing, token expiry) belongs
// to TC-SB116 in batch 2 and is not claimed here.
const fs = require('fs');
const path = require('path');

const PAYLOAD = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'board-payload.json'), 'utf8')
);
const SUPABASE_UMD = require.resolve('@supabase/supabase-js/dist/umd/supabase.js');

const SESSION = {
  access_token: 'qa-fixture-access-token',
  token_type: 'bearer',
  expires_in: 3600,
  expires_at: Math.floor(Date.now() / 1000) + 3600,
  refresh_token: 'qa-fixture-refresh-token',
  user: {
    id: '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e',
    aud: 'authenticated',
    role: 'authenticated',
    email: 'qa-fixture@supabrain.test',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { name: 'SupaBrain QA Fixture' },
    created_at: '2026-08-12T17:00:00Z',
  },
};

const json = (route, body) =>
  route.fulfill({
    status: 200,
    contentType: 'application/json',
    headers: { 'access-control-allow-origin': '*' },
    body: JSON.stringify(body),
  });

// PostgREST's archived=eq.<bool> filter, applied to fixture rows.
//
// SB-314: the boards hide archived items by fetching with `&archived=eq.false`
// and reveal them by DROPPING that parameter, so a stub that ignores the filter
// cannot tell the two states apart — the Archived chip would appear to work
// while changing nothing. Honouring it here is what makes the chip testable,
// and it also keeps the archived fixture row out of the default board so the
// seeded counts in fixture.js stay correct.
function applyArchivedFilter(url, rows) {
  const m = /[?&]archived=eq\.(true|false)/.exec(url);
  if (!m) return rows;                       // no filter: everything, archived included
  const want = m[1] === 'true';
  return rows.filter((r) => Boolean(r.archived) === want);
}

// The fixture pins agents.last_run_at to a literal date. relTime() in the
// boards reports "Nd ago" only inside a 7-day window and falls back to an
// absolute date beyond it, so a hard-coded timestamp makes TC-SB104 pass when
// it is written and fail forever after — which is exactly what happened; it
// went red on its own with no code change, twelve days after the seed date.
// Re-anchoring the timestamp at serve time keeps the assertion meaningful
// instead of weakening it. A null last_run_at stays null: agent two is the
// fixture's "never ran" case and TC-SB104 asserts that too.
const REL_HOURS_AGO = 2;
function freshenAgents(agents) {
  const stamp = new Date(Date.now() - REL_HOURS_AGO * 3600 * 1000).toISOString();
  return agents.map((a) => (a.last_run_at ? Object.assign({}, a, { last_run_at: stamp }) : a));
}

// Map a PostgREST path to its fixture rows.
function rowsFor(url, payload) {
  if (url.includes('/rest/v1/projects')) return applyArchivedFilter(url, payload.projects);
  if (url.includes('/rest/v1/labels')) return payload.labels;
  if (url.includes('/rest/v1/agents')) return freshenAgents(payload.agents);
  if (url.includes('/rest/v1/kanban_board_view')) return applyArchivedFilter(url, payload.items);
  return [];
}

// `payload` defaults to the baseline board; TC-SB118 swaps in the bulk variant.
// E2E_LIVE=1 drives the real backend instead of the replay. Until this was
// wired up the flag existed only as a sentence in tests/README.md — setting it
// changed nothing, which made "run it live" look like a one-command job when
// there was no mechanism behind it.
const LIVE = process.env.E2E_LIVE === '1';

async function installStubs(page, payload = PAYLOAD) {
  // The vendored supabase-js bundle is served in BOTH modes. Live mode is about
  // exercising the real Supabase backend, not the real CDN; serving the library
  // locally keeps the test from also depending on cdn.jsdelivr.net egress.
  await page.route('**/cdn.jsdelivr.net/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD })
  );

  // Live mode stops here: auth and REST go to the real origin.
  if (LIVE) return;

  await page.route('**/auth/v1/**', (route) => {
    const url = route.request().url();
    if (url.includes('/token')) return json(route, SESSION);
    if (url.includes('/logout')) return route.fulfill({ status: 204, body: '' });
    if (url.includes('/user')) return json(route, SESSION.user);
    return json(route, {});
  });

  await page.route('**/rest/v1/**', (route) => {
    if (route.request().method() !== 'GET') {
      // Batches 1 and 2 are read-only: a write here means a test did something
      // it should not, and the 405 makes that loud instead of silent.
      return route.fulfill({ status: 405, contentType: 'application/json', body: '{"message":"read-only batch"}' });
    }
    return json(route, rowsFor(route.request().url(), payload));
  });
}

module.exports = { installStubs, applyArchivedFilter, PAYLOAD, SESSION, LIVE };
