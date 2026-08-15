// Wave 6 — SB-358 and SB-359.
//
// Both tickets are about the board telling the truth when the server does
// something other than what was asked. Neither is reachable through the normal
// write stub, because both need the backend to misbehave in a specific way:
// SB-358 needs a write that SUCCEEDS with a different status than requested,
// SB-359 needs a failure carrying a real PostgREST error body.
//
// Playwright matches routes most-recently-registered first, so each test layers
// a narrow override on top of the write stub installed at login.
const { test, expect } = require('@playwright/test');
const { FIXTURE, openBoard, cardByTitle } = require('./fixture');
const { installWriteStubs } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

async function login(page) {
  if (!EMAIL || !PASSWORD) throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  await installWriteStubs(page);
  await page.goto('/jarvis-dashboard.html');
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-btn');
  await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
  await openBoard(page);
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
  return errors;
}

const toast = (page) => page.locator('.toast, #toast').last();
const dt = (page) => page.evaluateHandle(() => new DataTransfer());

async function dragTo(page, card, status) {
  const col = page.locator(`.column[data-status="${status}"]`);
  await card.dispatchEvent('dragstart', { dataTransfer: await dt(page) });
  await col.dispatchEvent('dragover', { dataTransfer: await dt(page) });
  await col.dispatchEvent('drop', { dataTransfer: await dt(page) });
}

test.describe('@wave6 SB-358 — a redirected status must not be reported as the requested one', () => {
  test('TC-358-01 a WIP-limit redirect is reflected on the board and named in the toast', async ({ page }) => {
    const errors = await login(page);
    const card = cardByTitle(page, FIXTURE.cards.rich);
    const id = await card.getAttribute('data-id');

    // The trigger's real behaviour: the move SUCCEEDS, but the stored status is
    // on_hold rather than the in_progress that was asked for.
    await page.route('**/rest/v1/rpc/move_work_item', (route) =>
      route.fulfill({ status: 200, contentType: 'application/json', body: 'null' }));
    await page.route(`**/rest/v1/work_items?select=id,status,sort_order&id=eq.${id}`, (route) =>
      route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([{ id, status: 'on_hold', sort_order: 0 }]),
      }));

    await dragTo(page, card, 'in_progress');

    // The card must land where the DATABASE put it, not where the drop aimed.
    await expect(page.locator('#col-on_hold .card').filter({ hasText: FIXTURE.cards.rich }))
      .toHaveCount(1);
    await expect(page.locator('#col-in_progress .card').filter({ hasText: FIXTURE.cards.rich }))
      .toHaveCount(0);

    // And the user must be told, rather than shown a success for a move that
    // did not happen as requested.
    await expect(toast(page)).toContainText('on hold');
    await expect(toast(page)).toContainText('redirected');
    expect(errors).toEqual([]);
  });

  test('TC-358-02 an unredirected move still reports plainly', async ({ page }) => {
    const errors = await login(page);
    const card = cardByTitle(page, FIXTURE.cards.rich);
    await dragTo(page, card, 'done');
    // Guard against the reconcile turning every ordinary move into a warning.
    await expect(toast(page)).toContainText('Moved to done');
    await expect(toast(page)).not.toContainText('redirected');
    expect(errors).toEqual([]);
  });
});

test.describe('@wave6 SB-359 — server errors reach the user as sentences, not payloads', () => {
  test('TC-359-01 a trigger error is shown as readable text with no JSON or SQLSTATE', async ({ page }) => {
    await login(page);
    const card = cardByTitle(page, FIXTURE.cards.rich);

    // The shape PostgREST actually returns when a trigger raises.
    await page.route('**/rest/v1/rpc/move_work_item', (route) =>
      route.fulfill({
        status: 400, contentType: 'application/json',
        body: JSON.stringify({
          code: 'P0001',
          details: null,
          hint: null,
          message: 'SB-327: no reviewer resolvable for project QA Fixture Alpha',
        }),
      }));

    await dragTo(page, card, 'review');

    const text = await toast(page).textContent();
    expect(text).toContain('No reviewer resolvable for project');
    // None of the machinery should surface.
    expect(text).not.toContain('P0001');
    expect(text).not.toContain('{');
    expect(text).not.toContain('SB-327');
    expect(text).not.toContain('hint');

    // The control flow that was already correct must stay correct: a failed
    // move leaves the card where it was.
    await expect(page.locator('#col-review .card').filter({ hasText: FIXTURE.cards.rich }))
      .toHaveCount(0);
  });

  test('TC-359-02 an error with no parseable body still says something', async ({ page }) => {
    await login(page);
    const card = cardByTitle(page, FIXTURE.cards.rich);
    await page.route('**/rest/v1/rpc/move_work_item', (route) =>
      route.fulfill({ status: 502, contentType: 'text/html', body: '<html>Bad Gateway</html>' }));

    await dragTo(page, card, 'done');
    // Must not swallow the failure, and must not dump markup at the user.
    await expect(toast(page)).toContainText('Move failed');
    await expect(toast(page)).toContainText('502');
    await expect(toast(page)).not.toContainText('<html>');
  });
});
