// Re-run of the SB-202 … SB-207 card-surface test cases (30 cases).
//
// These were last executed 2026-08-02 by code inspection and recorded 26 fail /
// 4 pass. This file executes them in a real browser against a fixture payload
// built to exercise every indicator they assert: ticket codes (present, absent,
// overlong), human/agent/unassigned combinations, all 8 statuses, every work
// item type, subtask counts, dependency counts and acknowledged state.
//
// Most cases specify BOTH surfaces — "Repeat on jarvis-pwa.html" — so a case
// passes only when the behaviour holds on both. The PWA implements this family;
// jarvis-dashboard.html largely does not, and that split is the finding.
const { test, expect } = require('@playwright/test');
const { loginPwa, pwaColumn, cardByTitle } = require('./fixture');
const { login } = require('./fixture');
const PAYLOAD = require('./fixtures/cards-payload.json');

const opts = { payload: PAYLOAD, expectTotal: PAYLOAD.items.length };

// The colours SB-204 pins the badges to.
const STAT_COLORS = {
  backlog: 'rgb(139, 148, 158)', todo: 'rgb(88, 166, 255)',
  in_progress: 'rgb(139, 92, 246)', on_hold: 'rgb(163, 113, 247)',
  blocked: 'rgb(248, 81, 73)', review: 'rgb(210, 153, 34)',
  escalated: 'rgb(240, 136, 62)', done: 'rgb(63, 185, 80)',
};
const ALL_STATUSES = Object.keys(STAT_COLORS);

// The dashboard needs its own browser context: a PWA login in the same context
// leaves a session behind, and the dashboard then auto-authenticates and hides
// the login form the helper drives.
async function pwaPage(browser, o, width) {
  const ctx = await browser.newContext({ viewport: { width, height: 800 } });
  const p = await ctx.newPage();
  const errs = await loginPwa(p, o);
  return { page: p, errs, close: () => ctx.close() };
}

async function dashPage(browser, o) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  await login(p, o);
  return p;
}

const dashCard = (page, title) => cardByTitle(page, title);
const pwaCard = (page, title) =>
  page.locator('.card').filter({ has: page.locator('.card-title', { hasText: title }) }).first();

/* ══════════════════ SB-202 — ticket code on cards ══════════════════ */
test.describe('@cards SB-202', () => {
  test('TC-202-01 ticket code displays on kanban cards — happy path', async ({ page, browser }) => {
    // PWA half.
    await loginPwa(page, opts);
    const code = pwaCard(page, 'Human assignee card').locator('.card-code');
    await expect(code).toHaveText('CARD-001');
    expect(await code.evaluate((e) => getComputedStyle(e).fontSize)).toBe('10px');

    // Dashboard half — step 3 requires the code in the card-meta row.
    const page2 = await dashPage(browser, opts);
    const dash = dashCard(page2, 'Human assignee card');
    await expect(dash).toBeVisible();
    await expect(dash.locator('.card-code'), 'dashboard card renders no ticket code').toHaveCount(1);
  });

  test('TC-202-02 ticket code uses monospace font styling', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const code = pwaCard(page, 'Human assignee card').locator('.card-code');
    const font = await code.evaluate((e) => getComputedStyle(e).fontFamily);
    expect(font.toLowerCase()).toContain('mono');
    const codeColor = await code.evaluate((e) => getComputedStyle(e).color);
    const titleColor = await pwaCard(page, 'Human assignee card')
      .locator('.card-title').evaluate((e) => getComputedStyle(e).color);
    expect(codeColor).not.toBe(titleColor);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Human assignee card').locator('.card-code')).toHaveCount(1);
  });

  test('TC-202-03 cards without ticket_code gracefully omit the element', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const bare = pwaCard(page, 'No ticket code card');
    await expect(bare).toBeVisible();
    await expect(bare.locator('.card-code')).toHaveCount(0);
    // The meta row must not keep a hole where the code would be: the priority
    // dot is flush against the row's left edge.
    const gap = await bare.evaluate((el) => {
      const meta = el.querySelector('.card-meta');
      const dot = el.querySelector('.pri-dot');
      return dot.getBoundingClientRect().left - meta.getBoundingClientRect().left;
    });
    expect(gap).toBeLessThan(2);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'No ticket code card')).toBeVisible();
  });

  test('TC-202-04 long ticket codes do not overflow card layout', async ({ page, browser }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await loginPwa(page, opts);
    const card = pwaCard(page, 'Long ticket code card');
    const overflow = await card.evaluate((el) => {
      const c = el.getBoundingClientRect();
      return Array.from(el.querySelectorAll('.card-meta > *'))
        .map((n) => n.getBoundingClientRect().right - c.right).filter((d) => d > 1);
    });
    expect(overflow, 'meta children overflow the card at 375px').toEqual([]);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Long ticket code card').locator('.card-code')).toHaveCount(1);
  });

  test('TC-202-05 ticket code is first element in card-meta row', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const first = await pwaCard(page, 'Human assignee card')
      .evaluate((el) => el.querySelector('.card-meta').firstElementChild.className);
    expect(first).toContain('card-code');

    const page2 = await dashPage(browser, opts);
    const dashFirst = await dashCard(page2, 'Human assignee card')
      .evaluate((el) => el.querySelector('.card-meta').firstElementChild.className);
    expect(dashFirst, 'dashboard meta row leads with the priority dot, not a code')
      .toContain('card-code');
  });
});

/* ══════════════════ SB-203 — assignee on the card surface ══════════════════ */
test.describe('@cards SB-203', () => {
  test('TC-203-01 human assignee name displays on kanban card — happy path', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const chip = pwaCard(page, 'Human assignee card').locator('.assignee-chip');
    await expect(chip).toBeVisible();
    await expect(chip).toContainText('Jason');
    await expect(chip.locator('.av')).toHaveText('JP');   // initials avatar

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Human assignee card').locator('.assignee-chip'),
      'dashboard shows no human assignee').toHaveCount(1);
  });

  test('TC-203-02 both human assignee and agent displayed together', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const card = pwaCard(page, 'Human plus agent card');
    await expect(card.locator('.assignee-chip')).toBeVisible();
    await expect(card.locator('.agent-chip')).toBeVisible();
    const [a, g] = await Promise.all([
      card.locator('.assignee-chip').evaluate((e) => e.getBoundingClientRect().right),
      card.locator('.agent-chip').evaluate((e) => e.getBoundingClientRect().left),
    ]);
    expect(a, 'assignee and agent chips overlap').toBeLessThanOrEqual(g + 1);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Human plus agent card').locator('.assignee-chip')).toHaveCount(1);
  });

  test('TC-203-03 agent-only assignment shows agent chip as before', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const card = pwaCard(page, 'Agent only card');
    await expect(card.locator('.agent-chip')).toBeVisible();
    await expect(card.locator('.assignee-chip')).toHaveCount(0);

    const page2 = await dashPage(browser, opts);
    const dash = dashCard(page2, 'Agent only card');
    await expect(dash.locator('.agent-chip')).toBeVisible();
    await expect(dash.locator('.agent-chip.unassigned')).toHaveCount(0);
  });

  test('TC-203-04 unassigned tickets show Unassigned chip', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const card = pwaCard(page, 'Unassigned card');
    await expect(card).toBeVisible();
    await expect(card.locator('.agent-chip.unassigned, .assignee-chip.unassigned'),
      'PWA renders no Unassigned chip').toHaveCount(1);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Unassigned card').locator('.agent-chip.unassigned'))
      .toContainText('Unassigned');
  });

  test('TC-203-05 PWA assignee display does not overflow on small screens', async ({ browser }) => {
    for (const width of [375, 320]) {
      const { page: p, errs, close } = await pwaPage(browser, opts, width);
      const card = pwaCard(p, 'Human plus agent card');
      const over = await card.evaluate((el) => {
        const c = el.getBoundingClientRect();
        return Array.from(el.querySelectorAll('.assignee-chip, .agent-chip'))
          .map((n) => n.getBoundingClientRect().right - c.right).filter((d) => d > 1);
      });
      expect(over, `assignee/agent overflow at ${width}px`).toEqual([]);
      // Tapping the assignee area opens the detail modal, not a separate action.
      await card.locator('.assignee-chip').click();
      await expect(p.locator('#modal-bg')).toHaveClass(/open/);
      await p.click('#m-close');
      expect(errs).toEqual([]);
      await close();
    }
  });
});

/* ══════════════════ SB-204 — status badge on every card ══════════════════ */
test.describe('@cards SB-204', () => {
  test('TC-204-01 all statuses display colored badge on kanban cards', async ({ page, browser }) => {
    await loginPwa(page, opts);
    for (const st of ALL_STATUSES) {
      await pwaColumn(page, st);
      const badge = pwaCard(page, `Status ${st} card`).locator('.status-badge');
      await expect(badge, `PWA ${st} badge`).toBeVisible();
    }

    const page2 = await dashPage(browser, opts);
    const missing = [];
    for (const st of ALL_STATUSES) {
      const n = await dashCard(page2, `Status ${st} card`).locator('.status-badge').count();
      if (!n) missing.push(st);
    }
    expect(missing, 'dashboard statuses with no badge').toEqual([]);
  });

  test('TC-204-02 status badge colors match STAT_COLORS mapping', async ({ page, browser }) => {
    await loginPwa(page, opts);
    for (const st of ALL_STATUSES) {
      await pwaColumn(page, st);
      const badge = pwaCard(page, `Status ${st} card`).locator('.status-badge');
      expect(await badge.evaluate((e) => getComputedStyle(e).color), `${st} text`)
        .toBe(STAT_COLORS[st]);
      // Background is the same hue at 15% opacity (rendered as rgba .15).
      const bg = await badge.evaluate((e) => getComputedStyle(e).backgroundColor);
      expect(bg, `${st} background`).toMatch(/^rgba\(/);
    }

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Status todo card').locator('.status-badge')).toHaveCount(1);
  });

  test('TC-204-03 badge size is subtle on desktop, more prominent on PWA', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const badge = pwaCard(page, 'Status todo card').locator('.status-badge');
    expect(await badge.evaluate((e) => getComputedStyle(e).fontSize)).toBe('8px');
    expect(await badge.evaluate((e) => getComputedStyle(e).textTransform)).toBe('uppercase');

    const page2 = await dashPage(browser, opts);
    const dashBadge = dashCard(page2, 'Status todo card').locator('.status-badge');
    await expect(dashBadge, 'dashboard todo badge (spec: 9px uppercase)').toHaveCount(1);
    expect(await dashBadge.evaluate((e) => getComputedStyle(e).fontSize)).toBe('9px');
  });

  test('TC-204-04 status badge visible in PWA search and filter views', async ({ page }) => {
    await loginPwa(page, opts);
    await page.fill('#b-search', 'Status');
    await page.waitForTimeout(200);
    const cards = page.locator('#cards-area .card');
    const n = await cards.count();
    expect(n).toBeGreaterThan(0);
    for (let i = 0; i < n; i++) {
      await expect(cards.nth(i).locator('.status-badge')).toBeVisible();
    }
  });

  test('TC-204-05 status badge does not cause excessive visual noise', async ({ page, browser }) => {
    await loginPwa(page, opts);
    // "Compact and non-overlapping" is the checkable half of this case: no meta
    // child may overlap another or leave the card.
    const bad = await pwaCard(page, 'Status todo card').evaluate((el) => {
      const c = el.getBoundingClientRect();
      const kids = Array.from(el.querySelectorAll('.card-meta > *')).map((n) => n.getBoundingClientRect());
      const out = kids.filter((r) => r.right > c.right + 1).length;
      let overlap = 0;
      for (let i = 0; i < kids.length; i++)
        for (let j = i + 1; j < kids.length; j++)
          if (kids[i].right > kids[j].left + 1 && kids[j].right > kids[i].left + 1) overlap++;
      return { out, overlap };
    });
    expect(bad).toEqual({ out: 0, overlap: 0 });

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Status todo card').locator('.status-badge')).toHaveCount(1);
  });
});

/* ══════════════════ SB-205 — project pills ══════════════════ */
test.describe('@cards SB-205', () => {
  test('TC-205-01 project pills render with icon, key, and ticket count', async ({ page }) => {
    await loginPwa(page, opts);
    const pills = page.locator('#proj-pills .proj-pill');
    await expect(pills.first()).toHaveText(/All/);
    expect(await pills.count()).toBeGreaterThan(1);
    for (const p of await pills.nth(1).all()) {
      await expect(p.locator('.pill-count')).toBeVisible();
    }
    expect(await pills.first().evaluate((e) => e.getBoundingClientRect().height))
      .toBeGreaterThanOrEqual(34);
  });

  test('TC-205-02 tapping a project pill filters board to that project', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await pwaColumn(page, 'todo');
    const before = await page.locator('#cards-area .card').count();
    const beta = page.locator('#proj-pills .proj-pill').filter({ hasText: 'Beta' }).first();
    await beta.click();
    await page.waitForTimeout(200);
    const after = await page.locator('#cards-area .card').count();
    expect(after).toBeLessThan(before);
    for (const c of await page.locator('#cards-area .card').all()) {
      await expect(c.locator('.card-title')).toContainText('Beta');
    }
    await page.locator('#proj-pills .proj-pill[data-id="all"]').click();
    await page.waitForTimeout(200);
    expect(await page.locator('#cards-area .card').count()).toBe(before);

    const page2 = await dashPage(browser, opts);
    await expect(page2.locator('.proj-pill'), 'dashboard has no project pills')
      .not.toHaveCount(0);
  });

  test('TC-205-03 All pill is default active state', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await expect(page.locator('#proj-pills .proj-pill[data-id="all"]')).toHaveClass(/active/);
    const actives = await page.locator('#proj-pills .proj-pill.active').count();
    expect(actives).toBe(1);

    const page2 = await dashPage(browser, opts);
    await expect(page2.locator('.proj-pill.active')).toHaveCount(1);
  });

  test('TC-205-04 PWA pill bar scrolls horizontally on overflow', async ({ browser }) => {
    for (const width of [375, 320]) {
      const { page: p, close } = await pwaPage(browser, opts, width);
      const bar = p.locator('#proj-pills');
      expect(await bar.evaluate((e) => getComputedStyle(e).overflowX)).toBe('auto');
      expect(await bar.evaluate((e) => getComputedStyle(e).scrollbarWidth)).toBe('none');
      await close();
    }
  });

  test('TC-205-05 board stats and agent utilization update on pill filter', async ({ page }) => {
    await loginPwa(page, opts);
    await pwaColumn(page, 'todo');
    const beta = page.locator('#proj-pills .proj-pill').filter({ hasText: 'Beta' }).first();
    const countBefore = await page.locator('.col-tab[data-st="todo"] .ct-count').textContent();
    await beta.click();
    await page.waitForTimeout(200);
    const countAfter = await page.locator('.col-tab[data-st="todo"] .ct-count').textContent();
    expect(Number(countAfter)).toBeLessThan(Number(countBefore));
    // Dev-automation toggle appears for a single-project view.
    await expect(page.locator('#pa-wrap')).toBeVisible();
  });
});

/* ══════════════════ SB-206 — card detail modal ══════════════════ */
test.describe('@cards SB-206', () => {
  test('TC-206-01 PWA modal has assignee input field that saves correctly', async ({ page }) => {
    await loginPwa(page, opts);
    await pwaCard(page, 'Human assignee card').click();
    await expect(page.locator('#modal-bg')).toHaveClass(/open/);
    const input = page.locator('#m-assignee');
    await expect(input).toBeVisible();
    await expect(input).toHaveValue('Jason Paulsen');   // pre-populated on edit
  });

  test('TC-206-02 ticket code badge displayed in modal header', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await pwaCard(page, 'Human assignee card').click();
    const badge = page.locator('#m-ticket-badge');
    await expect(badge).toBeVisible();
    await expect(badge).toHaveText('CARD-001');
    expect((await badge.evaluate((e) => getComputedStyle(e).fontFamily)).toLowerCase())
      .toContain('mono');
    await page.click('#m-close');
    // A card with no ticket_code shows no empty badge.
    await pwaCard(page, 'No ticket code card').click();
    await expect(page.locator('#m-ticket-badge')).toBeHidden();
    await page.click('#m-close');

    const page2 = await dashPage(browser, opts);
    await dashCard(page2, 'Human assignee card').click();
    await expect(page2.locator('#modal-overlay')).toHaveClass(/active/);
    await expect(page2.locator('#m-ticket-badge'),
      'dashboard modal header has no ticket code badge').toHaveCount(1);
  });

  test('TC-206-03 status dropdown has visual color indicator', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await pwaCard(page, 'Human assignee card').click();
    const dot = page.locator('#m-status-dot');
    await expect(dot).toBeVisible();
    expect(await dot.evaluate((e) => getComputedStyle(e).backgroundColor))
      .toBe(STAT_COLORS.todo);
    await page.selectOption('#m-status', 'blocked');
    expect(await dot.evaluate((e) => getComputedStyle(e).backgroundColor))
      .toBe(STAT_COLORS.blocked);
    await page.click('#m-close');

    // Dashboard half. Step 5 — "verify the color indicator updates immediately"
    // — has to be asserted here too, not just on the PWA. Checking only that the
    // element exists would pass against a modal whose indicator never updates,
    // which is precisely the defect SB-348 was; a QA-gate mutation check caught
    // this assertion being too weak to notice the handler being unbound.
    const page2 = await dashPage(browser, opts);
    await dashCard(page2, 'Human assignee card').click();
    const dashDot = page2.locator('#m-status-dot');
    await expect(dashDot, 'dashboard modal has no status colour indicator').toBeVisible();
    expect(await dashDot.evaluate((e) => getComputedStyle(e).backgroundColor),
      'dashboard indicator does not reflect the current status').toBe(STAT_COLORS.todo);
    await page2.selectOption('#m-status', 'blocked');
    expect(await dashDot.evaluate((e) => getComputedStyle(e).backgroundColor),
      'dashboard indicator did not update when the status changed').toBe(STAT_COLORS.blocked);
  });

  test('TC-206-04 created and updated timestamps shown in modal footer', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await pwaCard(page, 'Human assignee card').click();
    const ts = page.locator('#m-timestamps');
    await expect(ts).toBeVisible();
    await expect(page.locator('#m-created')).toContainText('Created');
    await expect(page.locator('#m-updated')).toContainText('Updated');
    expect(await ts.locator('input, textarea, select').count()).toBe(0);
    await page.click('#m-close');

    const page2 = await dashPage(browser, opts);
    await dashCard(page2, 'Human assignee card').click();
    await expect(page2.locator('#m-timestamps'),
      'dashboard modal shows no created/updated footer').toHaveCount(1);
  });

  test('TC-206-05 type badge visible in modal header', async ({ page, browser }) => {
    await loginPwa(page, opts);
    for (const [title, label] of [['Bug type card', 'Bug'], ['Story type card', 'Story']]) {
      await pwaCard(page, title).click();
      await expect(page.locator('#m-type-badge')).toBeVisible();
      await expect(page.locator('#m-type-badge')).toHaveText(label);
      await page.click('#m-close');
    }
    await pwaCard(page, 'Human assignee card').click();       // type = task
    await expect(page.locator('#m-type-badge')).toBeHidden();
    await page.click('#m-close');

    const page2 = await dashPage(browser, opts);
    await dashCard(page2, 'Bug type card').click();
    await expect(page2.locator('#m-type-badge'),
      'dashboard modal header has no type badge').toHaveCount(1);
  });
});

/* ══════════════════ SB-207 — type, subtask, dependency, attention ══════════════════ */
test.describe('@cards SB-207', () => {
  test('TC-207-01 type badge renders on cards for non-task types', async ({ page, browser }) => {
    await loginPwa(page, opts);
    for (const [title, cls, label] of [
      ['Bug type card', 'type-bug', 'Bug'],
      ['Story type card', 'type-story', 'Story'],
      ['Epic type card', 'type-epic', 'Epic'],
    ]) {
      const badge = pwaCard(page, title).locator('.type-badge');
      await expect(badge).toBeVisible();
      await expect(badge).toHaveText(label);
      await expect(badge).toHaveClass(new RegExp(cls));
    }
    await expect(pwaCard(page, 'Human assignee card').locator('.type-badge')).toHaveCount(0);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Bug type card').locator('.type-badge'),
      'dashboard renders no type badge').toHaveCount(1);
  });

  test('TC-207-02 subtask progress indicator shows N/M when children exist', async ({ page, browser }) => {
    await loginPwa(page, opts);
    const partial = pwaCard(page, 'Partial subtasks card').locator('.subtask-prog');
    await expect(partial).toContainText('3/5');
    await expect(partial).not.toHaveClass(/complete/);
    const done = pwaCard(page, 'Complete subtasks card').locator('.subtask-prog');
    await expect(done).toContainText('4/4');
    await expect(done).toHaveClass(/complete/);
    await expect(pwaCard(page, 'Human assignee card').locator('.subtask-prog')).toHaveCount(0);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Partial subtasks card').locator('.subtask-prog'),
      'dashboard renders no subtask progress').toHaveCount(1);
  });

  test('TC-207-03 blocked-by dependency count displays when present', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await expect(pwaCard(page, 'Twin dependency card').locator('.dep-indicator')).toContainText('2 deps');
    await expect(pwaCard(page, 'Single dependency card').locator('.dep-indicator'))
      .toContainText('1 dep');
    await expect(pwaCard(page, 'Human assignee card').locator('.dep-indicator')).toHaveCount(0);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Twin dependency card').locator('.dep-indicator'),
      'dashboard renders no dependency indicator').toHaveCount(1);
  });

  test('TC-207-04 unacknowledged high/critical items show attention indicator', async ({ page, browser }) => {
    await loginPwa(page, opts);
    await expect(pwaCard(page, 'Fresh high card').locator('.new-badge')).toBeVisible();
    await expect(pwaCard(page, 'Seen high card').locator('.new-badge')).toHaveCount(0);
    await expect(pwaCard(page, 'Fresh medium card').locator('.new-badge')).toHaveCount(0);

    const page2 = await dashPage(browser, opts);
    await expect(dashCard(page2, 'Fresh high card').locator('.new-badge'),
      'dashboard renders no attention indicator').toHaveCount(1);
  });

  test('TC-207-05 all SB-207 indicators work on both platforms without overflow', async ({ browser }) => {
    for (const width of [375, 320]) {
      const { page: p, close } = await pwaPage(browser, opts, width);
      const card = pwaCard(p, 'All indicators card');
      for (const sel of ['.type-badge', '.new-badge', '.subtask-prog', '.dep-indicator']) {
        await expect(card.locator(sel), `${sel} at ${width}px`).toBeVisible();
      }
      const over = await card.evaluate((el) => {
        const c = el.getBoundingClientRect();
        return Array.from(el.querySelectorAll('.card-meta > *, .card-foot *'))
          .map((n) => n.getBoundingClientRect().right - c.right).filter((d) => d > 1).length;
      });
      expect(over, `indicators overflow at ${width}px`).toBe(0);
      await close();
    }

    const page2 = await dashPage(browser, opts);
    const dash = dashCard(page2, 'All indicators card');
    const present = await dash.evaluate((el) => ({
      type: !!el.querySelector('.type-badge'), neu: !!el.querySelector('.new-badge'),
      sub: !!el.querySelector('.subtask-prog'), dep: !!el.querySelector('.dep-indicator'),
    }));
    expect(present, 'dashboard renders none of the four indicators')
      .toEqual({ type: true, neu: true, sub: true, dep: true });
  });
});
