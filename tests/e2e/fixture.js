// Shared helpers + expected values for the QA fixture board.
//
// The fixture lives in the live Supabase project under a dedicated QA user, so
// RLS scopes the board to exactly the rows seeded by tests/e2e/seed.sql. Every
// number below is derived from that seed — if the seed changes, change these.
const { expect } = require('@playwright/test');
const { installStubs } = require('./stub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

// Seeded distribution: 5 backlog / 2 todo / 3 in_progress / 5 review / 10 done.
// Chosen so the delivery bar lands on the exact percentages TC-02 specifies.
const FIXTURE = {
  total: 25,
  byStatus: {
    backlog: 5, todo: 2, in_progress: 3, on_hold: 0,
    blocked: 0, review: 5, escalated: 0, done: 10,
  },
  donePct: 40,
  inFlight: 10,          // todo + in_progress + review
  unassigned: 6,         // includes the 2 epics, which carry no agent
  segments: { done: '40%', review: '20%', prog: '12%' },
  domains: { products: 13, operations: 12 },
  alpha: { name: 'QA Fixture Alpha', total: 13, done: 5, donePct: 38, inFlight: 5, unassigned: 3 },
  beta: { name: 'QA Fixture Beta', total: 12, done: 5, donePct: 42, inFlight: 5, unassigned: 3 },
  empty: { name: 'QA Fixture Empty' },
  agents: {
    count: 2, owned: 19, open: 10, donePct: 47,
    one: { name: 'QA Fixture Agent One', icon: '🧪', total: 10, done: 5, open: 5, cap: 4,
           runs: '12', errors: '3', avg: '45.0s' },
    two: { name: 'QA Fixture Agent Two', icon: '🔬', total: 9, done: 4, open: 5, cap: 9,
           runs: '0', errors: '0', avg: '—', last: 'never' },
  },
  cards: {
    rich: 'Rich fixture card — all layers',
    bare: 'Bare fixture card',
    longTitle: 'Long title fixture card',
  },
  labelColors: { 'qa-fixture': 'rgb(88, 166, 255)', 'privacy-review': 'rgb(210, 153, 34)' },
  domainStripe: { products: 'rgb(139, 92, 246)', operations: 'rgb(247, 120, 186)' },
};

// The five columns TC-09 names, in the order it expects them, with the header
// colours defined in the stylesheet.
const SPEC_COLUMNS = [
  { status: 'backlog', title: 'Backlog', color: 'rgb(139, 148, 158)' },
  { status: 'todo', title: 'To Do', color: 'rgb(88, 166, 255)' },
  { status: 'in_progress', title: 'In Progress', color: 'rgb(139, 92, 246)' },
  { status: 'review', title: 'Review', color: 'rgb(210, 153, 34)' },
  { status: 'done', title: 'Done', color: 'rgb(63, 185, 80)' },
];

async function login(page) {
  if (!EMAIL || !PASSWORD) {
    throw new Error(
      'QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set — the fixture ' +
      'credentials are deliberately not committed to the repo.'
    );
  }
  const consoleErrors = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('pageerror', (e) => consoleErrors.push(String(e)));

  await installStubs(page);
  await page.goto('/jarvis-dashboard.html');
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-btn');

  await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
  await openBoard(page);
  // The board only paints once loadAll() resolves.
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
  return consoleErrors;
}

async function openBoard(page) {
  await page.click('.g-tab[data-tab="board"]');
  await expect(page.locator('#panel-board')).toHaveClass(/active/);
  await expect(page.locator('#board')).toBeVisible();
}

// Switch the project dropdown and wait for the re-render to settle.
async function selectProject(page, name) {
  const value = await page.locator('#project-select option')
    .filter({ hasText: name }).first().getAttribute('value');
  await page.selectOption('#project-select', value);
  await page.waitForTimeout(150);
  return value;
}

async function selectAllProjects(page) {
  await page.selectOption('#project-select', 'all');
  await page.waitForTimeout(150);
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));
}

// Locate a rendered card by its title text.
function cardByTitle(page, title) {
  return page.locator('.card').filter({ has: page.locator('.card-title', { hasText: title }) }).first();
}

module.exports = { FIXTURE, SPEC_COLUMNS, login, openBoard, selectProject, selectAllProjects, cardByTitle };
