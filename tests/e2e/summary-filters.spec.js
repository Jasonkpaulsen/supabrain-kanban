// SB-616 (regression of SB-209): summary cards filter the board.
//
// SB-209 made the summary cards clickable in cfe6a99; 81fa9ab removed it on 2026-07-08
// and TC-SB209-01 was recorded as passing four days later without exercising anything.
// Every case here clicks a card and checks that the board then shows EXACTLY the number
// printed on that card, so a filter and its count cannot drift apart again.
//
// Fixture: cards-payload.json plus fresh timestamps (so the Jarvis "last 24h" cards have
// something to count) and one cancelled, unassigned row changed an hour ago. The
// dashboard's Jarvis scope drops cancelled rows and the PWA's does not, so that row is
// what proves each surface filters by its own count rule. Stubbed backend, as in
// cards.spec.js.
const { test, expect } = require('@playwright/test');
const { login, loginPwa } = require('./fixture');
const BASE = require('./fixtures/cards-payload.json');

const HOUR = 3600 * 1000;
const iso = (ms) => new Date(Date.now() - ms).toISOString();
function buildPayload() {
  const p = JSON.parse(JSON.stringify(BASE));
  const done = p.items.find((i) => i.status === 'done');
  done.updated_at = iso(HOUR); done.completed_at = iso(HOUR);
  const fresh = p.items.filter((i) => i.status !== 'done').slice(0, 2);
  fresh.forEach((i) => { i.updated_at = iso(2 * HOUR); });
  p.items.filter((i) => i !== done && !fresh.includes(i)).forEach((i) => { i.updated_at = iso(72 * HOUR); });
  const template = p.items.find((i) => i.status === 'todo');
  p.items.push({ ...template, id: '00000000-0000-4000-8000-00000000c616', ticket_code: 'ZZC-616',
    title: 'SB616 cancelled fixture', status: 'cancelled', agent_name: null, assigned_agent_id: null,
    assignee: null, updated_at: iso(HOUR), sort_order: 9999 });
  return p;
}
const PAYLOAD = buildPayload();
const notCancelled = PAYLOAD.items.filter((i) => i.status !== 'cancelled').length;

// Read the number printed on a card ("5 38%" -> 5).
const num = async (loc) => parseInt(String(await loc.first().textContent()).trim(), 10);

// ── dashboard (jarvis-dashboard.html) ──────────────────────────────────────────
async function dashShown(page) {
  const counts = await page.locator('#board .column:visible .column-count').allTextContents();
  return counts.reduce((s, c) => s + Number(c || 0), 0);
}
async function dashLogin(browser) {
  const ctx = await browser.newContext(); const page = await ctx.newPage();
  const errs = await login(page, { payload: PAYLOAD, expectTotal: notCancelled });
  return { ctx, page, errs };
}

test.describe('@sb616 dashboard', () => {
  test('TC-SB616-01 board stat cards show exactly their own number; toggle, Total, chip and Clear All reset; aria-pressed', async ({ browser }) => {
    const { ctx, page, errs } = await dashLogin(browser);
    const baseline = await dashShown(page);
    for (const key of ['done', 'flight', 'unassigned']) {
      const card = page.locator(`#stats-strip .stat-card[data-sf="${key}"]`);
      const n = await num(card.locator('.stat-value'));
      await card.click();
      await expect(card).toHaveClass(/sf-active/);
      await expect(card).toHaveAttribute('aria-pressed', 'true');
      await expect(page.locator('#sf-chip')).toBeVisible();
      expect(await dashShown(page), key).toBe(n);
      await card.click();
      await expect(card).toHaveAttribute('aria-pressed', 'false');
      await expect(page.locator('#sf-chip')).toBeHidden();
      expect(await dashShown(page)).toBe(baseline);
    }
    // the cancelled row is unassigned, but Unassigned counts and filters without it
    expect(await num(page.locator('#s-unassigned'))).toBe(
      PAYLOAD.items.filter((i) => i.status !== 'cancelled' && !i.agent_name).length);
    await page.locator('#stats-strip .stat-card[data-sf="flight"]').click();
    await page.locator('#stats-strip .stat-card[data-sf="all"]').click();
    expect(await dashShown(page)).toBe(baseline);
    await page.locator('#stats-strip .stat-card[data-sf="unassigned"]').click();
    await page.locator('#sf-chip').click();
    await expect(page.locator('#sf-chip')).toBeHidden();
    await page.locator('#stats-strip .stat-card[data-sf="done"]').click();
    await page.locator('#filter-clear').evaluate((b) => b.click());
    await expect(page.locator('#sf-chip')).toBeHidden();
    await expect(page.locator('#stats-strip .sf-active')).toHaveCount(0);
    expect(await dashShown(page)).toBe(baseline);
    expect(errs).toEqual([]);
    await ctx.close();
  });

  test('TC-SB616-02 Jarvis Done / Changed: board equals the donut number (cancelled excluded), across a project pill and a domain chip', async ({ browser }) => {
    const { ctx, page, errs } = await dashLogin(browser);
    // a project pill is selected first: the Jarvis donuts count every project, so the click resets it
    await page.locator('#proj-pills .proj-pill:not([data-id="all"])').first().click();
    await page.click('.g-tab[data-tab="jarvis"]');
    await expect(page.locator('#j-stats .j-stat-card[data-sf]')).toHaveCount(2);      // Decided, Flagged: display-only
    for (const key of ['done24', 'changed24']) {
      await page.click('.g-tab[data-tab="jarvis"]');
      const card = page.locator(`#j-stats .j-stat-card[data-sf="${key}"]`);
      const n = await num(card.locator('.j-stat-num'));
      await card.click();
      await expect(page.locator('#panel-board')).toHaveClass(/active/);
      await expect(page.locator('#proj-pills .proj-pill[data-id="all"]')).toHaveClass(/active/);
      await expect(page.locator('#sf-chip')).toBeFocused();
      expect(await dashShown(page), key).toBe(n);
      if (key === 'changed24') expect(n).toBe(3);   // 3 fresh rows; the fresh cancelled row is excluded here
      await page.locator('#sf-chip').click();
    }
    // a non-'all' Jarvis domain: the filter uses that domain, and changing domain clears it
    await page.click('.g-tab[data-tab="jarvis"]');
    await page.locator('#j-domain-bar .j-chip[data-jdomain="products"]').click();
    const card = page.locator('#j-stats .j-stat-card[data-sf="changed24"]');
    const n = await num(card.locator('.j-stat-num'));
    await card.click();
    expect(await dashShown(page)).toBe(n);
    await expect(page.locator('#sf-chip')).toContainText('products');
    await page.click('.g-tab[data-tab="jarvis"]');
    await page.locator('#j-domain-bar .j-chip[data-jdomain="all"]').click();
    await expect(page.locator('#sf-chip')).toBeHidden();
    expect(errs).toEqual([]);
    await ctx.close();
  });

  test('TC-SB616-03 keyboard: Enter and Space operate the cards; focus is kept', async ({ browser }) => {
    const { ctx, page, errs } = await dashLogin(browser);
    const card = page.locator('#stats-strip .stat-card[data-sf="flight"]');
    await card.focus();
    await page.keyboard.press('Enter');
    await expect(card).toHaveClass(/sf-active/);
    await page.keyboard.press(' ');
    await expect(card).not.toHaveClass(/sf-active/);
    await page.click('.g-tab[data-tab="jarvis"]');
    const jc = page.locator('#j-stats .j-stat-card[data-sf="done24"]');
    await jc.focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#sf-chip')).toBeFocused();
    await page.keyboard.press('Enter');                 // the chip clears the filter
    await expect(page.locator('#sf-chip')).toBeHidden();
    expect(errs).toEqual([]);
    await ctx.close();
  });
});

// ── PWA (jarvis-pwa.html) and index.html, which share the code ─────────────────
async function pwaShown(page) {
  const t = await page.locator('#fd-count').textContent();
  return Number(String(t).split(' of ')[0]);
}

for (const doc of ['/jarvis-pwa.html', '/index.html']) {
  test.describe(`@sb616 ${doc}`, () => {
    test(`TC-SB616-04 ${doc}: board and Jarvis cards show exactly their own number; pill, domain, keyboard, Clear All`, async ({ browser }) => {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const page = await ctx.newPage();
      const errs = await loginPwa(page, { payload: PAYLOAD, doc });
      await page.click('#stats-toggle');
      const baseline = await pwaShown(page);
      for (const key of ['done', 'flight', 'unassigned']) {
        const card = page.locator(`.b-stats-grid .b-stat[data-sf="${key}"]`);
        const n = await num(card.locator('.val'));
        await card.click();
        await expect(card).toHaveAttribute('aria-pressed', 'true');
        await expect(page.locator('#sf-chip')).toBeVisible();
        expect(await pwaShown(page), key).toBe(n);
        await card.click();
        await expect(page.locator('#sf-chip')).toBeHidden();
      }
      expect(await pwaShown(page)).toBe(baseline);
      // keyboard on a board card
      const fl = page.locator('.b-stats-grid .b-stat[data-sf="flight"]');
      await fl.focus(); await page.keyboard.press('Enter');
      await expect(fl).toHaveClass(/sf-active/);
      await page.keyboard.press(' ');
      await expect(fl).not.toHaveClass(/sf-active/);
      // Jarvis cards, after a project pill was selected
      await page.locator('#proj-pills .proj-pill:not([data-id="all"])').first().click();
      await page.click('.nav-btn[data-tab="jarvis"]');
      await expect(page.locator('#j-stats .j-stat[data-sf]')).toHaveCount(2);
      for (const key of ['done24', 'changed24']) {
        await page.click('.nav-btn[data-tab="jarvis"]');
        const card = page.locator(`#j-stats .j-stat[data-sf="${key}"]`);
        const n = await num(card.locator('.j-stat-n'));
        await card.click();
        await expect(page.locator('#p-board')).toHaveClass(/active/);
        await expect(page.locator('#proj-pills .proj-pill[data-id="all"]')).toHaveClass(/active/);
        expect(await pwaShown(page), key).toBe(n);
        if (key === 'changed24') expect(n).toBe(4);   // the PWA's Jarvis scope keeps the cancelled row
        await page.locator('#sf-chip').click();
      }
      // a non-'all' Jarvis domain, then a domain change clears it
      await page.click('.nav-btn[data-tab="jarvis"]');
      await page.locator('#j-chips .j-chip[data-d="products"]').click();
      const card = page.locator('#j-stats .j-stat[data-sf="changed24"]');
      const n = await num(card.locator('.j-stat-n'));
      await card.click();
      expect(await pwaShown(page)).toBe(n);
      await page.click('.nav-btn[data-tab="jarvis"]');
      await page.locator('#j-chips .j-chip[data-d="all"]').click();
      await expect(page.locator('#sf-chip')).toBeHidden();
      // Clear All resets a board-card filter
      await page.click('.nav-btn[data-tab="board"]');
      await page.locator('.b-stats-grid .b-stat[data-sf="done"]').click();
      await page.locator('#fd-clear').evaluate((b) => b.click());
      await expect(page.locator('#sf-chip')).toBeHidden();
      await expect(page.locator('.b-stats-grid .sf-active')).toHaveCount(0);
      expect(await pwaShown(page)).toBe(baseline);
      expect(errs).toEqual([]);
      await ctx.close();
    });
  });
}
