// SB-771 — the Needs Jason lane, the Approve / Reject / Un-approve decision and
// the header badge, on all three boards (jarvis-dashboard.html, jarvis-pwa.html,
// index.html).
//
// Transport: the batch-3 write stub, extended with rpc/is_jason_session and
// rpc/decide_work_item. The stub applies SB-770's status rules so the card can
// be seen landing where the server would put it, but it is NOT the database —
// the real guard, rules and audit rows are covered by TC-SB770-V1..V15 in SQL.
// What these cases prove is the client half: the right wire call (exactly one
// RPC, never a PATCH), the options only where they belong, the refusal shown
// as the database wrote it, and the board re-read afterwards.
const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { installWriteStubs, requestsFor, BASE } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

// The PWA registers sw.js, and once it claims the page its fetches leave
// through the service worker, where page.route() no longer sees them. Blocking
// the worker keeps every request on the stub.
test.use({ serviceWorkers: 'block' });

// ── Fixture: the base board plus five approval cases ─────────────────────────
const proj = BASE.projects[0];
const base = BASE.items.find((i) => i.ticket_code === 'QAA-001');
function mk(id, code, title, extra) {
  return Object.assign({}, base, {
    id, ticket_code: code, title, type: 'task', labels: [], archived: false,
    project_id: proj.id, project_name: proj.name, project_icon: proj.icon, project_domain: proj.domain,
    approval_status: 'pending', authority_level: 3, needs_jason: false, needs_jason_kind: null,
    waiting_days: null, aging_breached: false, decision_needed: null, sort_order: 50,
  }, extra);
}
const NJ = {
  pkg: mk('00000000-0000-4000-8000-000000000771', 'NJ-PKG', 'Decision package card',
    { status: 'awaiting_jason', authority_level: 4, needs_jason: true, needs_jason_kind: 'decision_package',
      waiting_days: 0.4, decision_needed: 'Pick vendor A or B' }),
  old: mk('00000000-0000-4000-8000-000000000772', 'NJ-OLD', 'Old approval card',
    { status: 'backlog', authority_level: 3, needs_jason: true, needs_jason_kind: 'approval_only',
      waiting_days: 55.1, aging_breached: true }),
  fresh: mk('00000000-0000-4000-8000-000000000773', 'NJ-NEW', 'Fresh approval card',
    { status: 'backlog', authority_level: 2, needs_jason: true, needs_jason_kind: 'approval_only', waiting_days: 2 }),
  low: mk('00000000-0000-4000-8000-000000000774', 'NJ-L1', 'Level one pending card',
    { status: 'backlog', authority_level: 1 }),
  approved: mk('00000000-0000-4000-8000-000000000775', 'NJ-APR', 'Approved level three card',
    { status: 'todo', authority_level: 3, approval_status: 'approved', approved_by: 'Jason Paulsen' }),
};
const SEED = Object.assign({}, BASE, { items: BASE.items.concat(Object.values(NJ)) });
const LIVE_TOTAL = SEED.items.filter((i) => !i.archived).length;   // 25 + 5

function guard(page) {
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  // Reject must ask for its note inline. Any browser dialog is a failure.
  page.on('dialog', (d) => { errors.push('unexpected dialog: ' + d.message()); d.dismiss(); });
  return errors;
}
function needCreds() {
  if (!EMAIL || !PASSWORD) throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
}

async function dash(page, isJason) {
  needCreds();
  const errors = guard(page);
  const backend = await installWriteStubs(page, SEED, { isJason });
  await page.goto('/jarvis-dashboard.html');
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-btn');
  await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
  await page.click('.g-tab[data-tab="board"]');
  await expect(page.locator('#s-total')).toHaveText(String(LIVE_TOTAL), { timeout: 20000 });
  return { backend, errors };
}

async function pwa(page, file, isJason) {
  needCreds();
  const errors = guard(page);
  const backend = await installWriteStubs(page, SEED, { isJason });
  await page.goto('/' + file);
  await page.fill('#l-email', EMAIL);
  await page.fill('#l-pass', PASSWORD);
  await page.click('#l-btn');
  await expect(page.locator('#login-overlay')).toBeHidden({ timeout: 20000 });
  await expect(page.locator('#nj-badge')).toBeVisible({ timeout: 20000 });
  return { backend, errors };
}

const decisions = (b) => requestsFor(b, 'POST', '/rpc/decide_work_item');
const patches = (b) => requestsFor(b, 'PATCH', '/rest/v1/work_items');
const lastToast = (page) => page.locator('.toast').last();
const dashCard = (page, scope, title) =>
  page.locator(scope + ' .card').filter({ has: page.locator('.card-title', { hasText: title }) });

/* ═══════════════════════════ desktop dashboard ═══════════════════════════ */
test.describe('@sb771 dashboard', () => {
  test('TC-SB771-V1 Needs Jason lane is first, ordered, counted, and holds each card once', async ({ page }) => {
    const { errors } = await dash(page, true);
    const lane = page.locator('#nj-lane');
    await expect(lane).toBeVisible();
    // First thing on the board, before the Backlog column.
    expect(await page.locator('#board > *').first().getAttribute('id')).toBe('nj-lane');
    await expect(page.locator('#count-needs_jason')).toHaveText('3');
    // Decision package first, then approval-only by waiting days, longest first.
    await expect(page.locator('#col-needs_jason .card .card-code')).toHaveText(['NJ-PKG', 'NJ-OLD', 'NJ-NEW']);
    await expect(dashCard(page, '#col-needs_jason', 'Decision package card').locator('.nj-kind')).toHaveText('Decision package');
    await expect(dashCard(page, '#col-needs_jason', 'Old approval card').locator('.nj-kind')).toHaveText('Approval only · Backlog');
    // Shown in the lane only, never twice, and the lane is not a drop target.
    await expect(dashCard(page, '#col-backlog', 'Old approval card')).toHaveCount(0);
    await expect(page.locator('#count-backlog')).toHaveText('6');   // 5 fixture + the L1 card
    await expect(lane).not.toHaveClass(/\bcolumn\b/);
    expect(await page.locator('#col-needs_jason .card').first().getAttribute('draggable')).toBe('false');
    // L1 and already-approved cards stay in their own columns.
    await expect(dashCard(page, '#col-backlog', 'Level one pending card')).toHaveCount(1);
    await expect(dashCard(page, '#col-todo', 'Approved level three card')).toHaveCount(1);
    expect(errors).toEqual([]);
  });

  test('TC-SB771-V2 header badge shows the count, turns amber on an aging breach, and filters to the lane', async ({ page }) => {
    const { errors } = await dash(page, true);
    const badge = page.locator('#nj-badge');
    await expect(badge).toBeVisible();
    await expect(page.locator('#nj-count')).toHaveText('3');
    await expect(badge).toHaveClass(/aged/);
    // From the JARVIS tab, a tap opens the board filtered to the lane.
    await page.click('.g-tab[data-tab="jarvis"]');
    await badge.click();
    await expect(page.locator('#panel-board')).toHaveClass(/active/);
    await expect(page.locator('#nj-lane')).toBeVisible();
    const shown = await page.locator('.column').evaluateAll((els) =>
      els.filter((e) => getComputedStyle(e).display !== 'none').length);
    expect(shown).toBe(0);
    await expect(page.locator('#status-chips .chip[data-status="needs_jason"]')).toHaveClass(/active/);
    // Attention Required lists the Needs Jason items first.
    await page.click('.g-tab[data-tab="jarvis"]');
    await expect(page.locator('#j-attention-list .j-att-card').first()).toContainText('NJ-PKG');
    expect(errors).toEqual([]);
  });

  test('TC-SB771-V3 Approve is one decide_work_item call, no PATCH, and the backlog card lands in To Do', async ({ page }) => {
    const { backend, errors } = await dash(page, true);
    await dashCard(page, '#col-needs_jason', 'Fresh approval card').click();
    await expect(page.locator('#m-status option[value="decide:approve"]')).toHaveCount(1);
    await page.selectOption('#m-status', 'decide:approve');
    await expect(lastToast(page)).toContainText('NJ-NEW approved');
    await expect(lastToast(page)).toContainText('To Do');
    expect(decisions(backend)).toHaveLength(1);
    expect(decisions(backend)[0].body).toEqual({ p_item_id: NJ.fresh.id, p_decision: 'approve', p_note: null });
    expect(patches(backend)).toHaveLength(0);
    // Re-read from the server: the card left the lane and sits in To Do.
    await expect(dashCard(page, '#col-todo', 'Fresh approval card')).toHaveCount(1);
    await expect(page.locator('#count-needs_jason')).toHaveText('2');
    await expect(page.locator('#nj-count')).toHaveText('2');
    expect(errors).toEqual([]);
  });

  test('TC-SB771-V4 Reject asks for its note inline, refuses an empty note, and lands the card On Hold', async ({ page }) => {
    const { backend, errors } = await dash(page, true);
    await dashCard(page, '#col-needs_jason', 'Old approval card').click();
    await page.selectOption('#m-status', 'decide:reject');
    await expect(page.locator('#m-reject-row')).toBeVisible();
    await page.click('#m-reject-go');
    expect(decisions(backend)).toHaveLength(0);
    await expect(page.locator('#m-reject-note')).toBeFocused();
    await page.fill('#m-reject-note', 'Not this quarter');
    await page.click('#m-reject-go');
    await expect(lastToast(page)).toContainText('NJ-OLD rejected');
    expect(decisions(backend)).toHaveLength(1);
    expect(decisions(backend)[0].body).toEqual({ p_item_id: NJ.old.id, p_decision: 'reject', p_note: 'Not this quarter' });
    expect(patches(backend)).toHaveLength(0);
    await expect(dashCard(page, '#col-on_hold', 'Old approval card')).toHaveCount(1);
    expect(errors).toEqual([]);
  });

  test('TC-SB771-V5 a database refusal is shown in the toast as the database wrote it', async ({ page }) => {
    const { backend, errors } = await dash(page, true);
    const msg = "SB-769: only Jason may approve L3/L4. Use the Kanban board, or have JARVIS record his chat approval with decide_work_item_chat and his exact quote.";
    await page.route('**/rest/v1/rpc/decide_work_item', (route) => route.fulfill({
      status: 403, contentType: 'application/json',
      body: JSON.stringify({ code: '42501', message: msg, details: null, hint: null }),
    }));
    await dashCard(page, '#col-needs_jason', 'Decision package card').click();
    await page.selectOption('#m-status', 'decide:approve');
    await expect(lastToast(page)).toHaveText(msg);
    await expect(lastToast(page)).toHaveClass(/error/);
    // Nothing moved, and the select went back to the stored status.
    await expect(page.locator('#m-status')).toHaveValue('awaiting_jason');
    await expect(dashCard(page, '#col-needs_jason', 'Decision package card')).toHaveCount(1);
    expect(patches(backend)).toHaveLength(0);
    // The page logs the refusal to the console on purpose (SB-359 pattern).
    expect(errors.filter((e) => !/Request failed|403/.test(e))).toEqual([]);
  });

  test('TC-SB771-V6 decision options appear only for an L2+ card in Jason\'s session', async ({ page, browser }) => {
    const { errors } = await dash(page, true);
    // L1: no decision options, and Awaiting Jason is not offered as a target.
    await dashCard(page, '#col-backlog', 'Level one pending card').click();
    await expect(page.locator('#m-status option[value^="decide:"]')).toHaveCount(0);
    await expect(page.locator('#m-status option[value="awaiting_jason"]')).toHaveCount(0);
    await page.click('#btn-cancel-modal');
    // Approved L3 in To Do: Reject and Un-approve, no second Approve.
    await dashCard(page, '#col-todo', 'Approved level three card').click();
    const vals = await page.locator('#m-status option[value^="decide:"]').evaluateAll((o) => o.map((x) => x.value));
    expect(vals).toEqual(['decide:reject', 'decide:unapprove']);
    await page.click('#btn-cancel-modal');
    expect(errors).toEqual([]);

    // Same board, a session that is not Jason's: the lane still shows, no options.
    const ctx = await browser.newContext({ serviceWorkers: 'block' });
    const p2 = await ctx.newPage();
    await dash(p2, false);
    await expect(p2.locator('#count-needs_jason')).toHaveText('3');
    await dashCard(p2, '#col-needs_jason', 'Old approval card').click();
    await expect(p2.locator('#m-status option[value^="decide:"]')).toHaveCount(0);
    await expect(p2.locator('#col-needs_jason .nj-approve')).toHaveCount(0);
    await ctx.close();
  });

  test('TC-SB771-V7 Un-approve sends the card back to Needs Jason; the lane chip approves in one tap', async ({ page }) => {
    const { backend, errors } = await dash(page, true);
    await dashCard(page, '#col-todo', 'Approved level three card').click();
    await page.selectOption('#m-status', 'decide:unapprove');
    await expect(lastToast(page)).toContainText('NJ-APR un-approved');
    await expect(dashCard(page, '#col-needs_jason', 'Approved level three card')).toHaveCount(1);
    await page.click('#btn-cancel-modal');
    // One-tap Approve chip on a lane card: one call, card back to To Do.
    await dashCard(page, '#col-needs_jason', 'Approved level three card').locator('.nj-approve').click();
    await expect(dashCard(page, '#col-todo', 'Approved level three card')).toHaveCount(1);
    expect(decisions(backend).map((r) => r.body.p_decision)).toEqual(['unapprove', 'approve']);
    expect(patches(backend)).toHaveLength(0);
    await expect(page.locator('#modal-overlay')).not.toHaveClass(/active/);
    expect(errors).toEqual([]);
  });
});

/* ═══════════════════════ iPhone PWA and index.html ═══════════════════════ */
for (const file of ['jarvis-pwa.html', 'index.html']) {
  test.describe(`@sb771 ${file}`, () => {
    test(`TC-SB771-V8 ${file}: badge, first tab, and lane order`, async ({ page }) => {
      const { errors } = await pwa(page, file, true);
      await expect(page.locator('#nj-count')).toHaveText('3');
      await expect(page.locator('#nj-badge')).toHaveClass(/aged/);
      await page.click('#nj-badge');
      await expect(page.locator('#p-board')).toHaveClass(/active/);
      await expect(page.locator('.col-tab').first()).toHaveAttribute('data-st', 'needs_jason');
      await expect(page.locator('.col-tab[data-st="needs_jason"]')).toHaveClass(/active/);
      await expect(page.locator('.col-tab[data-st="needs_jason"] .ct-count')).toHaveText('3');
      await expect(page.locator('#cards-area .card .card-code')).toHaveText(['NJ-PKG', 'NJ-OLD', 'NJ-NEW']);
      // Not shown twice: the Backlog tab no longer counts the lane cards.
      await expect(page.locator('.col-tab[data-st="backlog"] .ct-count')).toHaveText('6');
      expect(errors).toEqual([]);
    });

    test(`TC-SB771-V9 ${file}: move sheet decisions — Approve, inline Reject, refusal`, async ({ page }) => {
      const { backend, errors } = await pwa(page, file, true);
      await page.click('#nj-badge');
      // Long-press opens the move sheet; the same function the touch timer calls.
      await page.evaluate((id) => openMoveSheet(id), NJ.fresh.id);
      await expect(page.locator('#move-sheet')).toHaveClass(/open/);
      await expect(page.locator('.move-opt[data-decide]')).toHaveCount(2);   // approve + reject (pending)
      await page.click('.move-opt[data-decide="approve"]');
      await expect(lastToast(page)).toContainText('NJ-NEW approved');
      expect(decisions(backend)).toHaveLength(1);
      expect(decisions(backend)[0].body).toEqual({ p_item_id: NJ.fresh.id, p_decision: 'approve', p_note: null });
      await expect(page.locator('.col-tab[data-st="needs_jason"] .ct-count')).toHaveText('2');

      // Reject: the note is asked for inside the sheet, never by a dialog.
      await page.evaluate((id) => openMoveSheet(id), NJ.old.id);
      await page.click('.move-opt[data-decide="reject"]');
      await expect(page.locator('#move-reject')).toBeVisible();
      await page.click('#move-reject-go');
      expect(decisions(backend)).toHaveLength(1);
      await page.fill('#move-reject-note', 'Not this quarter');
      await page.click('#move-reject-go');
      await expect(lastToast(page)).toContainText('NJ-OLD rejected');
      expect(decisions(backend)[1].body).toEqual({ p_item_id: NJ.old.id, p_decision: 'reject', p_note: 'Not this quarter' });
      await page.click('.col-tab[data-st="on_hold"]');
      await expect(page.locator('#cards-area .card-title', { hasText: 'Old approval card' })).toHaveCount(1);

      // A refusal comes back verbatim.
      const msg = "SB-770: decide_work_item is only for Jason's own Kanban login. JARVIS records a chat decision with decide_work_item_chat.";
      await page.route('**/rest/v1/rpc/decide_work_item', (route) => route.fulfill({
        status: 403, contentType: 'application/json',
        body: JSON.stringify({ code: '42501', message: msg, details: null, hint: null }),
      }));
      await page.evaluate((id) => openMoveSheet(id), NJ.pkg.id);
      await page.click('.move-opt[data-decide="approve"]');
      await expect(lastToast(page)).toHaveText(msg);
      expect(patches(backend)).toHaveLength(0);
      expect(errors.filter((e) => !/403/.test(e))).toEqual([]);
    });

    test(`TC-SB771-V10 ${file}: no decision options for L1 or for a session that is not Jason's`, async ({ page, browser }) => {
      const { errors } = await pwa(page, file, true);
      await page.evaluate((id) => openMoveSheet(id), NJ.low.id);
      await expect(page.locator('.move-opt[data-decide]')).toHaveCount(0);
      await expect(page.locator('.move-opt[data-st="awaiting_jason"]')).toHaveCount(0);
      await page.click('#move-cancel');
      // Approved L3 in To Do: Reject and Un-approve, plus Awaiting Jason as a move target.
      await page.evaluate((id) => openMoveSheet(id), NJ.approved.id);
      const opts = await page.locator('.move-opt[data-decide]').evaluateAll((b) => b.map((x) => x.dataset.decide));
      expect(opts).toEqual(['reject', 'unapprove']);
      await expect(page.locator('.move-opt[data-st="awaiting_jason"]')).toHaveCount(1);
      await page.click('#move-cancel');
      expect(errors).toEqual([]);

      const ctx = await browser.newContext({ serviceWorkers: 'block' });
      const p2 = await ctx.newPage();
      await pwa(p2, file, false);
      await expect(p2.locator('#nj-count')).toHaveText('3');
      await p2.evaluate((id) => openMoveSheet(id), NJ.old.id);
      await expect(p2.locator('.move-opt[data-decide]')).toHaveCount(0);
      await ctx.close();
    });
  });
}

/* ═════════════════════════════════ sw.js ═════════════════════════════════ */
test('@sb771 TC-SB771-V11 sw.js cache is jarvis-pwa-v12 so the iPhone app picks up the new board', async () => {
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'sw.js'), 'utf8');
  expect(src).toMatch(/const CACHE_NAME = 'jarvis-pwa-v12';/);
  expect(src).not.toMatch(/jarvis-pwa-v11/);
});
