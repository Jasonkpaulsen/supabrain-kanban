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

// Map a PostgREST path to its fixture rows.
function rowsFor(url, payload) {
  if (url.includes('/rest/v1/projects')) return payload.projects;
  if (url.includes('/rest/v1/labels')) return payload.labels;
  if (url.includes('/rest/v1/agents')) return payload.agents;
  if (url.includes('/rest/v1/kanban_board_view')) return payload.items;
  return [];
}

// `payload` defaults to the baseline board; TC-SB118 swaps in the bulk variant.
async function installStubs(page, payload = PAYLOAD) {
  // Vendored supabase-js in place of the blocked CDN.
  await page.route('**/cdn.jsdelivr.net/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD })
  );

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

module.exports = { installStubs, PAYLOAD, SESSION };
