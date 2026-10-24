// SB-565 — the cancelled state on all three boards (spec docs/ui/SB-564-cancelled-state.md,
// ADR-FLOW-004). TC-SB565-1..8.
//
// Client half only, like batch 3: the write stub applies the happy path of
// rpc/cancel_work_item and rpc/reopen_work_item and records the wire calls. The
// database rules (reason, note, authority, parent guard, audit) are proven by
// supabase/tests/ticket_cancellation_suite.sql against the live project.
const { test, expect } = require('@playwright/test');
const { FIXTURE, openBoard, cardByTitle } = require('./fixture');
const { installWriteStubs, requestsFor, BASE } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;
const ACTOR = 'SupaBrain QA Fixture';   // the stub session's user_metadata.name

// The fixture board plus one cancelled ticket: a duplicate of "Alpha todo item".
const CANCELLED_TITLE = 'Withdrawn fixture card — cancelled as a duplicate';
function seedWithCancelled() {
  const seed = JSON.parse(JSON.stringify(BASE));
  const twin = seed.items.find((i) => i.ticket_code === 'QAA-004');
  seed.items.push(Object.assign({}, twin, {
    id: '0b0e5650-5650-4565-8565-000000000565', ticket_code: 'QAA-050', title: CANCELLED_TITLE,
    status: 'cancelled', completed_at: null, labels: [], comment_count: 0, child_count: 0,
    completed_child_count: 0, blocked_by_count: 0, acknowledged: false, priority: 'high',
    due_date: '2026-01-01', cancel_reason: 'duplicate', cancel_note: null,
    cancel_replaced_by: twin.id, cancelled_by: 'Jason', cancelled_at: '2026-10-10T03:00:00Z',
  }));
  return seed;
}

function needCreds() {
  if (!EMAIL || !PASSWORD) throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
}

async function loginDashboard(page, seed) {
  needCreds();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const backend = await installWriteStubs(page, seed);
  await page.goto('/jarvis-dashboard.html');
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-btn');
  await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
  await openBoard(page);
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
  return { backend, errors };
}

async function loginMobile(page, file, seed) {
  needCreds();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.setViewportSize({ width: 360, height: 780 });
  const backend = await installWriteStubs(page, seed);
  await page.goto('/' + file);
  await page.fill('#l-email', EMAIL);
  await page.fill('#l-pass', PASSWORD);
  await page.click('#l-btn');
  await expect(page.locator('#login-overlay')).toBeHidden({ timeout: 20000 });
  await page.click('.nav-btn[data-tab="board"]');
  await expect(page.locator('#cards-area')).toBeVisible({ timeout: 30000 });
  await expect(page.locator('#bs-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
  return { backend, errors };
}

async function mobileTab(page, status) {
  await page.click(`.col-tab[data-st="${status}"]`);
  await expect(page.locator(`.col-tab[data-st="${status}"]`)).toHaveClass(/active/);
}

const noHorizontalScroll = (page) => page.evaluate(() => {
  const d = document.documentElement;
  const dlg = document.getElementById('cancel-dlg');
  return d.scrollWidth <= d.clientWidth && (!dlg || dlg.scrollWidth <= dlg.clientWidth);
});

test.describe('@sb565 cancelled state', () => {
  test('TC-SB565-1/2 dashboard: a cancelled card reads as cancelled and leaves the totals', async ({ page }) => {
    const { errors } = await loginDashboard(page, seedWithCancelled());
    // 25 live items + 1 cancelled: totals and done % are exactly the fixture's.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));
    await expect(page.locator('#s-done-pct')).toHaveText(`${FIXTURE.donePct}%`);
    await expect(page.locator('#count-cancelled')).toHaveText('1');
    const card = page.locator('#col-cancelled .card').filter({ hasText: CANCELLED_TITLE });
    await expect(card).toHaveCount(1);
    await expect(card).toHaveClass(/cancelled/);
    await expect(card.locator('.status-badge')).toHaveText('Cancelled');
    await expect(card.locator('.card-cancel')).toHaveText('Duplicate of QAA-004 · Jason');
    await expect(card.locator('.new-badge')).toHaveCount(0);
    await expect(card.locator('.card-due.overdue')).toHaveCount(0);
    await expect(page.locator('#col-done .card').filter({ hasText: CANCELLED_TITLE })).toHaveCount(0);
    const deco = await card.locator('.card-title').evaluate((el) => getComputedStyle(el).textDecorationLine);
    expect(deco).toContain('line-through');
    await expect(page.locator('.add-card-btn[data-status="cancelled"]')).toHaveCount(0);
    expect(errors).toEqual([]);
  });

  test('TC-SB565-3 dashboard: cancel end to end from the modal', async ({ page }) => {
    const { backend, errors } = await loginDashboard(page);
    await cardByTitle(page, FIXTURE.cards.bare).click();
    await expect(page.locator('#btn-cx')).toHaveText('Cancel ticket…');
    await page.click('#btn-cx');
    await expect(page.locator('#cancel-dlg-bg')).toHaveClass(/open/);
    await expect(page.locator('#cx-h')).toHaveText('Cancel QAA-003?');
    const go = page.locator('#cx-go');
    await expect(go).toBeDisabled();
    await page.click('.cx-reason[data-r="duplicate"]');
    await page.fill('#cx-input', 'x');
    await expect(go).toBeDisabled();
    await page.click('.cx-reason[data-r="wont_do"]');
    await page.fill('#cx-input', 'ab');
    await expect(go).toBeDisabled();
    await page.click('.cx-reason[data-r="duplicate"]');
    await page.fill('#cx-input', 'qaa-004');
    await expect(go).toBeEnabled();
    await go.click();
    await expect(page.locator('#cancel-dlg-bg')).not.toHaveClass(/open/);
    await expect.poll(() => requestsFor(backend, 'POST', '/rpc/cancel_work_item').length).toBe(1);
    const calls = requestsFor(backend, 'POST', '/rpc/cancel_work_item');
    expect(calls).toHaveLength(1);
    expect(calls[0].body).toMatchObject({ p_reason: 'duplicate', p_replaced_by: 'QAA-004', p_note: null, p_actor: ACTOR });
    await expect(page.locator('#col-cancelled .card').filter({ hasText: FIXTURE.cards.bare })).toHaveCount(1, { timeout: 10000 });
    // An open item left: total drops by one, done stays put.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total - 1));
    const done = await page.locator('#s-done').evaluate((el) => el.firstChild.textContent.trim());
    expect(done).toBe(String(FIXTURE.byStatus.done));
    expect(errors).toEqual([]);
  });

  test('TC-SB565-5 a server refusal stays in the dialog', async ({ page }) => {
    const { backend } = await loginDashboard(page);
    backend.state.refuse = { rpc: 'cancel_work_item', message: 'CANCEL-003: only Jason can cancel QAA-003 (L3, status backlog; actor: x)' };
    await cardByTitle(page, FIXTURE.cards.bare).click();
    await page.click('#btn-cx');
    await page.click('.cx-reason[data-r="wont_do"]');
    await page.fill('#cx-input', 'not needed');
    await page.click('#cx-go');
    await expect(page.locator('#cx-err')).toContainText('CANCEL-003');
    await expect(page.locator('#cancel-dlg-bg')).toHaveClass(/open/);
    await page.click('#cx-keep');
    await expect(page.locator('#col-backlog .card').filter({ hasText: FIXTURE.cards.bare })).toHaveCount(1);
  });

  test('TC-SB565-6 reopen, and the awaiting_jason fallback', async ({ page }) => {
    const { backend } = await loginDashboard(page, seedWithCancelled());
    await page.locator('#col-cancelled .card').filter({ hasText: CANCELLED_TITLE }).click();
    await expect(page.locator('#m-cx-banner')).toBeVisible();
    await expect(page.locator('#m-cx-banner')).toContainText('Duplicate of QAA-004');
    await expect(page.locator('#m-status')).toBeDisabled();
    await expect(page.locator('#btn-cx')).toHaveText('Reopen');
    await page.click('#btn-cx');
    await expect(page.locator('#col-backlog .card').filter({ hasText: CANCELLED_TITLE })).toHaveCount(1, { timeout: 10000 });
    let calls = requestsFor(backend, 'POST', '/rpc/reopen_work_item');
    expect(calls.map((c) => c.body.p_status)).toEqual(['backlog']);

    // An L3 / rejected ticket: the server refuses backlog, the board retries for Jason's queue.
    const it = backend.state.items.find((i) => i.ticket_code === 'QAA-050');
    Object.assign(it, { status: 'cancelled', cancel_reason: 'rejected_by_jason', cancel_note: 'declined', cancelled_by: 'Jason' });
    backend.state.refuse = { rpc: 'reopen_work_item', status: 'backlog', message: 'CANCEL-005: QAA-050 (L3, rejected_by_jason) can only be reopened to awaiting_jason' };
    await page.evaluate(() => loadAll());
    await page.locator('#col-cancelled .card').filter({ hasText: CANCELLED_TITLE }).click();
    await page.click('#btn-cx');
    await expect(page.locator('.toast').last()).toContainText("waiting for Jason's decision", { timeout: 10000 });
    calls = requestsFor(backend, 'POST', '/rpc/reopen_work_item');
    expect(calls.map((c) => c.body.p_status)).toEqual(['backlog', 'backlog', 'awaiting_jason']);
  });

  test('TC-SB565-7 status pickers never offer Cancelled; a drop on Cancelled opens the dialog', async ({ page }) => {
    const { backend } = await loginDashboard(page);
    await expect(page.locator('#m-status option[value="cancelled"]')).toHaveCount(0);
    // Dispatch the HTML5 drag events on the exact card: a pointer-driven drag
    // across a horizontally scrolled board can pick up a neighbouring card.
    const dt = await page.evaluateHandle(() => new DataTransfer());
    await cardByTitle(page, FIXTURE.cards.bare).dispatchEvent('dragstart', { dataTransfer: dt });
    await page.locator('.column[data-status="cancelled"]').dispatchEvent('drop', { dataTransfer: dt });
    await expect(page.locator('#cancel-dlg-bg')).toHaveClass(/open/);
    await expect(page.locator('#cx-h')).toHaveText('Cancel QAA-003?');
    expect(requestsFor(backend, 'POST', '/rpc/move_work_item')).toHaveLength(0);
  });

  test('TC-SB565-1/4 PWA at 360px: cancelled tab, card, and cancel from the move sheet', async ({ page }) => {
    const { backend, errors } = await loginMobile(page, 'jarvis-pwa.html', seedWithCancelled());
    await expect(page.locator('#bs-total')).toHaveText(String(FIXTURE.total));
    await mobileTab(page, 'cancelled');
    const card = page.locator('#cards-area .card').filter({ hasText: CANCELLED_TITLE });
    await expect(card).toHaveClass(/cancelled/);
    await expect(card.locator('.status-badge')).toHaveText('Cancelled');
    await expect(card.locator('.card-cancel')).toHaveText('Duplicate of QAA-004 · Jason');
    expect(await noHorizontalScroll(page)).toBe(true);

    // Long-press opens the move sheet: Cancelled is not a move target; Cancel ticket… is.
    await mobileTab(page, 'backlog');
    const bare = page.locator('#cards-area .card').filter({ hasText: FIXTURE.cards.bare });
    await bare.dispatchEvent('touchstart');
    await expect(page.locator('#move-sheet')).toHaveClass(/open/, { timeout: 3000 });
    await expect(page.locator('#move-opts .move-opt[data-st="cancelled"]')).toHaveCount(0);
    await page.click('#move-cx');
    await expect(page.locator('#cancel-dlg-bg')).toHaveClass(/open/);
    await page.click('.cx-reason[data-r="wont_do"]');
    await page.fill('#cx-input', 'Dropped from the plan');
    expect(await noHorizontalScroll(page)).toBe(true);
    await page.click('#cx-go');
    await expect(page.locator('#cancel-dlg-bg')).not.toHaveClass(/open/);
    await expect.poll(() => requestsFor(backend, 'POST', '/rpc/cancel_work_item').length).toBe(1);
    const calls = requestsFor(backend, 'POST', '/rpc/cancel_work_item');
    expect(calls[0].body).toMatchObject({ p_reason: 'wont_do', p_note: 'Dropped from the plan', p_replaced_by: null, p_actor: ACTOR });
    await mobileTab(page, 'cancelled');
    await expect(page.locator('#cards-area .card').filter({ hasText: FIXTURE.cards.bare })).toHaveCount(1, { timeout: 10000 });
    await expect(page.locator('#bs-total')).toHaveText(String(FIXTURE.total - 1));
    expect(errors).toEqual([]);
  });

  test('TC-SB565-8 index.html parity', async ({ page }) => {
    const { errors } = await loginMobile(page, 'index.html', seedWithCancelled());
    await mobileTab(page, 'cancelled');
    const card = page.locator('#cards-area .card').filter({ hasText: CANCELLED_TITLE });
    await expect(card).toHaveClass(/cancelled/);
    await expect(card.locator('.card-cancel')).toHaveText('Duplicate of QAA-004 · Jason');
    await card.click();
    await expect(page.locator('#btn-cx')).toHaveText('Reopen');
    await expect(page.locator('#m-cx-banner')).toBeVisible();
    expect(errors).toEqual([]);
  });
});
