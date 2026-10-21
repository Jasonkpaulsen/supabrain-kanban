// SB-616 (regression of SB-209): summary cards filter the board.
//
// SB-209 made the summary cards clickable in cfe6a99; 81fa9ab removed it on 2026-07-08
// and TC-SB209-01 was recorded as passing four days later without exercising anything.
// These cases click every summary card on both surfaces and check that the board then
// shows EXACTLY the items the card counted, that the filter is visible and clearable,
// and that the display-only cards (Decided, Flagged) are not clickable.
//
// The payload is cards-payload.json with fresh timestamps on a few rows, so the Jarvis
// "last 24h" cards have something to count. Stubbed backend, as in cards.spec.js.
const { test, expect } = require('@playwright/test');
const { login, loginPwa } = require('./fixture');
const BASE = require('./fixtures/cards-payload.json');

const HOUR = 3600 * 1000;
function payloadWithFreshRows() {
  const p = JSON.parse(JSON.stringify(BASE));
  const iso = (ms) => new Date(Date.now() - ms).toISOString();
  const done = p.items.find((i) => i.status === 'done');
  done.updated_at = iso(HOUR); done.completed_at = iso(HOUR);       // done in the last 24h
  const others = p.items.filter((i) => i.status !== 'done').slice(0, 2);
  others.forEach((i) => { i.updated_at = iso(2 * HOUR); });          // changed in the last 24h
  p.items.filter((i) => i !== done && !others.includes(i)).forEach((i) => { i.updated_at = iso(72 * HOUR); });
  return p;
}
const PAYLOAD = payloadWithFreshRows();
const live = PAYLOAD.items.filter((i) => i.status !== 'cancelled' && !i.archived);
const EXPECT = {
  done24: live.filter((i) => i.status === 'done' && i.completed_at && Date.now() - Date.parse(i.completed_at) < 24 * HOUR).length,
  changed24: live.filter((i) => Date.now() - Date.parse(i.updated_at) < 24 * HOUR).length,
  done: live.filter((i) => i.status === 'done').length,
  flight: live.filter((i) => ['todo', 'in_progress', 'review', 'escalated'].includes(i.status)).length,
  unassigned: live.filter((i) => !i.agent_name).length,
  total: live.length,
};
const opts = { payload: PAYLOAD, expectTotal: PAYLOAD.items.length };

// ── dashboard (jarvis-dashboard.html) ──────────────────────────────────────────
async function dashShown(page) {
  const counts = await page.locator('#board .column:visible .column-count').allTextContents();
  return counts.reduce((s, c) => s + Number(c || 0), 0);
}

test.describe('@sb616 dashboard', () => {
  test('TC-SB209-01a board stat cards filter to exactly what they count; chip and Clear reset', async ({ browser }) => {
    const ctx = await browser.newContext(); const page = await ctx.newPage();
    const errs = await login(page, opts);
    for (const key of ['done', 'flight', 'unassigned']) {
      const card = page.locator(`#stats-strip .stat-card[data-sf="${key}"]`);
      await card.click();
      await expect(card).toHaveClass(/sf-active/);
      await expect(page.locator('#sf-chip')).toBeVisible();
      expect(await dashShown(page), key).toBe(EXPECT[key]);
      await card.click();                                   // same card again clears
      await expect(card).not.toHaveClass(/sf-active/);
      await expect(page.locator('#sf-chip')).toBeHidden();
      expect(await dashShown(page)).toBe(EXPECT.total);
    }
    await page.locator('#stats-strip .stat-card[data-sf="flight"]').click();
    await page.locator('#stats-strip .stat-card[data-sf="all"]').click();   // Total clears
    expect(await dashShown(page)).toBe(EXPECT.total);
    await page.locator('#stats-strip .stat-card[data-sf="unassigned"]').click();
    await page.locator('#sf-chip').click();                                  // the chip clears
    await expect(page.locator('#sf-chip')).toBeHidden();
    expect(await dashShown(page)).toBe(EXPECT.total);
    expect(errs).toEqual([]);
    await ctx.close();
  });

  test('TC-SB209-01b Jarvis Done / Changed open the board filtered; Decided and Flagged are display-only', async ({ browser }) => {
    const ctx = await browser.newContext(); const page = await ctx.newPage();
    const errs = await login(page, { ...opts, skipBoard: true });
    await page.click('.g-tab[data-tab="jarvis"]');
    const doneCard = page.locator('#j-stats .j-stat-card[data-sf="done24"]');
    await expect(doneCard).toBeVisible({ timeout: 30000 });
    await expect(page.locator('#j-stats .j-stat-card[data-sf]')).toHaveCount(2);   // Decided, Flagged: no data-sf
    for (const key of ['done24', 'changed24']) {
      await page.click('.g-tab[data-tab="jarvis"]');
      await page.locator(`#j-stats .j-stat-card[data-sf="${key}"]`).click();
      await expect(page.locator('#panel-board')).toHaveClass(/active/);
      await expect(page.locator('#sf-chip')).toBeVisible();
      expect(await dashShown(page), key).toBe(EXPECT[key]);
      await page.locator('#sf-chip').click();
    }
    expect(EXPECT.done24).toBe(1);
    expect(EXPECT.changed24).toBe(3);
    expect(errs).toEqual([]);
    await ctx.close();
  });
});

// ── PWA (jarvis-pwa.html; index.html shares the code) ──────────────────────────
async function pwaShown(page) {
  const t = await page.locator('#fd-count').textContent();
  return Number(String(t).split(' of ')[0]);
}

for (const doc of ['/jarvis-pwa.html', '/index.html']) {
  test.describe(`@sb616 ${doc}`, () => {
    test(`TC-SB209-01c ${doc}: board and Jarvis summary cards filter the board`, async ({ browser }) => {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const page = await ctx.newPage();
      const errs = await loginPwa(page, { payload: PAYLOAD, doc });
      await page.click('#stats-toggle');
      for (const key of ['done', 'flight', 'unassigned']) {
        const card = page.locator(`.b-stats-grid .b-stat[data-sf="${key}"]`);
        await card.click();
        await expect(card).toHaveClass(/sf-active/);
        await expect(page.locator('#sf-chip')).toBeVisible();
        expect(await pwaShown(page), key).toBe(EXPECT[key]);
        await card.click();
        await expect(page.locator('#sf-chip')).toBeHidden();
      }
      expect(await pwaShown(page)).toBe(EXPECT.total);
      await page.click('.nav-btn[data-tab="jarvis"]');
      await expect(page.locator('#j-stats .j-stat[data-sf]')).toHaveCount(2);
      await page.locator('#j-stats .j-stat[data-sf="done24"]').click();
      await expect(page.locator('#p-board')).toHaveClass(/active/);
      expect(await pwaShown(page)).toBe(EXPECT.done24);
      await page.click('.nav-btn[data-tab="jarvis"]');
      await page.locator('#j-stats .j-stat[data-sf="changed24"]').click();
      expect(await pwaShown(page)).toBe(EXPECT.changed24);
      await page.locator('#fd-clear').evaluate((b) => b.click());             // Clear All resets it too
      await expect(page.locator('#sf-chip')).toBeHidden();
      expect(await pwaShown(page)).toBe(EXPECT.total);
      expect(errs).toEqual([]);
      await ctx.close();
    });
  });
}
