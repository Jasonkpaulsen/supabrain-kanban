// SB-314 / ADR-FLOW-003 — the Archived reveal, on the dashboard.
//
// ADR-FLOW-003 rev 2 listed "a third unscoped frontend" among the ten defects
// it fixed, and SB-314 scope item 7 says "three boards, not two". index.html
// and jarvis-pwa.html shipped the full treatment; jarvis-dashboard.html carried
// only a hard-coded `&archived=eq.false` with no chip, no styling and no way
// back — so 720 of ~1,100 work items were unreachable from that surface.
//
// The reveal is NOT a client-side filter. Archived rows are excluded by the
// PostgREST query, so they are not in memory to show: toggling the chip has to
// re-fetch. That is why the stub honours `archived=eq.<bool>` (see stub.js) —
// without it the chip would appear to work while changing nothing, which is
// exactly the failure this suite exists to catch.
const { test, expect } = require('@playwright/test');
const { FIXTURE, login, openBoard, cardByTitle } = require('./fixture');

// The one archived row in fixtures/board-payload.json. Deliberately worded so
// that no other fixture title is a substring of it and it is a substring of
// none: Playwright's hasText is a case-insensitive SUBSTRING match, and that
// trap already produced one spurious failure in this suite (TC-207-04).
const ARCHIVED_CARD = 'Swept fixture card — archived by the retention sweep';

const chip = (page) => page.locator('#chip-archived');
const archivedCard = (page) => cardByTitle(page, ARCHIVED_CARD);

test.describe('@sb314 the dashboard can reveal archived items', () => {
  test('TC-314-01 archived items are hidden by default and do not distort the counts', async ({ page }) => {
    const errors = await login(page);
    await openBoard(page);

    // The seeded totals are the whole point: an archived row leaking into the
    // default board would inflate every count in fixture.js.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
    await expect(archivedCard(page)).toHaveCount(0);

    // The chip exists and is off.
    await expect(chip(page)).toBeVisible();
    await expect(chip(page)).toHaveText('Show archived');
    await expect(chip(page)).not.toHaveClass(/active/);
    expect(errors).toEqual([]);
  });

  test('TC-314-02 the chip reveals the archived card, dimmed and badged', async ({ page }) => {
    const errors = await login(page);
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });

    await chip(page).click();

    // The row arrives from a re-fetch, so wait on the card rather than a tick.
    await expect(archivedCard(page)).toHaveCount(1, { timeout: 20000 });
    // It lands in its real column, in place beside live work — the filter is
    // dropped, not inverted, so this is not a separate archived-only list.
    await expect(page.locator('#col-done .card').filter({ hasText: ARCHIVED_CARD })).toHaveCount(1);
    // ...and the live cards are still there.
    await expect(cardByTitle(page, FIXTURE.cards.rich)).toHaveCount(1);

    // Archived styling and marker.
    await expect(archivedCard(page)).toHaveClass(/archived/);
    await expect(archivedCard(page).locator('.card-arch')).toHaveText('Archived');
    expect(errors).toEqual([]);
  });

  test('TC-314-03 the active chip is actually visible', async ({ page }) => {
    await login(page);
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });

    await chip(page).click();
    await expect(chip(page)).toHaveClass(/active/);

    // .chip.active supplies white text and NO background — the status and
    // domain chips each carry their own inline one. A standalone chip without
    // an explicit fill renders white-on-background and disappears exactly when
    // it matters. Assert the contrast, not merely the class.
    const paint = await chip(page).evaluate((el) => {
      const s = getComputedStyle(el);
      return { bg: s.backgroundColor, color: s.color };
    });
    const transparent = (c) => c === 'transparent' || /rgba\(0,\s*0,\s*0,\s*0\)/.test(c);
    expect(transparent(paint.bg)).toBe(false);
    expect(paint.bg).not.toBe(paint.color);
  });

  test('TC-314-04 toggling back off hides the archived card again', async ({ page }) => {
    const errors = await login(page);
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });

    await chip(page).click();
    await expect(archivedCard(page)).toHaveCount(1, { timeout: 20000 });

    await chip(page).click();
    await expect(archivedCard(page)).toHaveCount(0, { timeout: 20000 });
    await expect(chip(page)).toHaveText('Show archived');
    await expect(chip(page)).not.toHaveClass(/active/);
    // Back to the seeded totals, so the reveal left nothing behind.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));
    expect(errors).toEqual([]);
  });

  test('TC-314-05 Clear resets the reveal', async ({ page }) => {
    const errors = await login(page);
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });

    await chip(page).click();
    await expect(archivedCard(page)).toHaveCount(1, { timeout: 20000 });

    // Clear owns every other filter on this bar; it must own this one too, or
    // the board is left in a state the Clear button claims to have cleared.
    await page.locator('#filter-clear').click();
    await expect(archivedCard(page)).toHaveCount(0, { timeout: 20000 });
    await expect(chip(page)).not.toHaveClass(/active/);
    await expect(chip(page)).toHaveText('Show archived');
    expect(errors).toEqual([]);
  });
});
