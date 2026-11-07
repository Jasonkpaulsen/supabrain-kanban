// SB-817 — board search matches the ticket code, on all three boards
// (jarvis-dashboard.html, jarvis-pwa.html, index.html).
//
// Jason, 2026-11-07: "where is sb-808, search won't pull it up when i search ticket
// number". The haystack left out ticket_code, so a ticket was found by its code only
// when the code happened to appear in its own text. The seeded target below carries
// SB-808 as its code and nowhere in its text, so these cases fail without the fix.
//
// Transport: the batch-3 write stub (read paths only are exercised). It is not the
// database; it proves the client half: kanban_board_view rows carry ticket_code and
// the search matches it, case-insensitively, while title search is unchanged.
const { test, expect } = require('@playwright/test');
const { installWriteStubs, BASE } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

test.use({ serviceWorkers: 'block' });

const proj = BASE.projects[0];
const base = BASE.items.find((i) => i.ticket_code === 'QAA-001');
function mk(id, code, title, description) {
  return Object.assign({}, base, {
    id, ticket_code: code, title, description, type: 'task', labels: [], archived: false,
    project_id: proj.id, project_name: proj.name, project_icon: proj.icon, project_domain: proj.domain,
    status: 'todo', authority_level: 1, approval_status: 'approved',
    needs_jason: false, needs_jason_kind: null, waiting_days: null, aging_breached: false,
    decision_needed: null, sort_order: 1, assignee: null, agent_name: null, agent_icon: null,
  });
}
const T = {
  target: mk('00000000-0000-4000-8000-000000000817', 'SB-808', 'Ticket code search target', 'The code is only in ticket_code.'),
  decoy: mk('00000000-0000-4000-8000-000000000818', 'SB-809', 'Ticket code search decoy', 'A neighbouring ticket that must not match.'),
};
const SEED = Object.assign({}, BASE, { items: BASE.items.concat(Object.values(T)) });
const LIVE_TOTAL = SEED.items.filter((i) => !i.archived).length;

function guard(page) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => { errors.push('unexpected dialog: ' + d.message()); d.dismiss(); });
  return errors;
}

async function open(page, file) {
  if (!EMAIL || !PASSWORD) throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
  const errors = guard(page);
  const backend = await installWriteStubs(page, SEED);
  await page.goto('/' + file);
  if (file === 'jarvis-dashboard.html') {
    await page.fill('#login-email', EMAIL);
    await page.fill('#login-password', PASSWORD);
    await page.click('#login-btn');
    await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
    await page.click('.g-tab[data-tab="board"]');
    await expect(page.locator('#s-total')).toHaveText(String(LIVE_TOTAL), { timeout: 20000 });
  } else {
    await page.fill('#l-email', EMAIL);
    await page.fill('#l-pass', PASSWORD);
    await page.click('#l-btn');
    await expect(page.locator('#login-overlay')).toBeHidden({ timeout: 20000 });
    await page.waitForFunction((n) => Array.isArray(window.items) && window.items.length === n, LIVE_TOTAL, { timeout: 20000 });
    await page.click('.nav-btn[data-tab="board"]');
  }
  return { backend, errors };
}

const BOARDS = {
  'jarvis-dashboard.html': { search: '#search-input', count: '#result-count', card: (id) => `.card[data-id="${id}"]` },
  'jarvis-pwa.html': { search: '#b-search', count: '#fd-count', card: (id) => `#cards-area .card[data-id="${id}"]` },
  'index.html': { search: '#b-search', count: '#fd-count', card: (id) => `#cards-area .card[data-id="${id}"]` },
};

for (const [file, ui] of Object.entries(BOARDS)) {
  test.describe(`@sb817 ${file}`, () => {
    test('TC-SB817-1 the loaded board items carry ticket_code', async ({ page }) => {
      const { errors } = await open(page, file);
      const codes = await page.evaluate(() => (window.allItems || window.items).map((i) => i.ticket_code));
      expect(codes).toContain('SB-808');
      expect(codes.every((c) => typeof c === 'string' && c.length > 0)).toBe(true);
      expect(errors).toEqual([]);
    });

    test('TC-SB817-2 SB-808, sb-808 and 808 each find SB-808 and hide tickets that do not match', async ({ page }) => {
      const { errors } = await open(page, file);
      const target = page.locator(ui.card(T.target.id));
      const decoy = page.locator(ui.card(T.decoy.id));
      // Both are visible before searching, so the hide below is the search's doing.
      await expect(target).toBeVisible();
      await expect(decoy).toBeVisible();
      for (const q of ['SB-808', 'sb-808', '808']) {
        await page.fill(ui.search, q);
        await expect(target, `search "${q}"`).toBeVisible();
        await expect(target.locator('.card-code')).toHaveText('SB-808');
        await expect(decoy, `search "${q}" hides SB-809`).toHaveCount(0);
        await expect(page.locator(ui.count), `search "${q}" count`).toHaveText(/^1 of \d+ shown$/);
      }
      await page.fill(ui.search, '');
      await expect(decoy).toBeVisible();
      expect(errors).toEqual([]);
    });

    test('TC-SB817-3 title search still works and a non-matching query shows nothing', async ({ page }) => {
      const { errors } = await open(page, file);
      const target = page.locator(ui.card(T.target.id));
      const decoy = page.locator(ui.card(T.decoy.id));
      await page.fill(ui.search, 'search decoy');
      await expect(decoy).toBeVisible();
      await expect(target).toHaveCount(0);
      await expect(page.locator(ui.count)).toHaveText(/^1 of \d+ shown$/);
      await page.fill(ui.search, 'TICKET CODE SEARCH TARGET');
      await expect(target).toBeVisible();
      await expect(decoy).toHaveCount(0);
      // Description search unchanged too.
      await page.fill(ui.search, 'neighbouring ticket');
      await expect(decoy).toBeVisible();
      await expect(target).toHaveCount(0);
      await page.fill(ui.search, 'qqqzzzxxx-no-such-ticket');
      await expect(page.locator(ui.count)).toHaveText(/^0 of \d+ shown$/);
      await expect(target).toHaveCount(0);
      expect(errors).toEqual([]);
    });
  });
}
