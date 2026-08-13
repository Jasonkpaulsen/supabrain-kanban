// QA batch 2/3 — SB-340. Filter, search, modal close paths, session, and
// large-dataset performance. Interaction-driven but still non-mutating: the
// stub answers any non-GET with 405, so an accidental write fails loudly.
const { test, expect } = require('@playwright/test');
const {
  FIXTURE, login, openBoard, selectProject, selectAllProjects, cardByTitle,
} = require('./fixture');
const { withBulk, BULK_TOTALS, EDGE } = require('./fixtures/bulk');
const { PAYLOAD } = require('./stub');

const ALL_STATUSES = ['backlog', 'todo', 'in_progress', 'on_hold', 'blocked', 'review', 'escalated', 'done'];

const visibleColumns = (page) =>
  page.locator('.column').evaluateAll((els) =>
    els.filter((e) => getComputedStyle(e).display !== 'none').map((e) => e.dataset.status));

const resultCount = (page) => page.locator('#result-count').textContent();

test.describe('@batch2 SB-340', () => {
  // ── TC-05 ──────────────────────────────────────────────────────────────
  test('TC-SB105 status chip filter collapses the board to a single column', async ({ page }) => {
    const errors = await login(page);

    // Baseline: every column on show.
    expect(await visibleColumns(page)).toEqual(ALL_STATUSES);
    expect(await resultCount(page)).toBe('25 of 25 shown');

    // Step 1-3: In Progress only.
    await page.click('#status-chips .chip[data-status="in_progress"]');
    expect(await visibleColumns(page)).toEqual(['in_progress']);
    expect(await resultCount(page)).toBe('3 of 25 shown');
    await expect(page.locator('#status-chips .chip[data-status="in_progress"]')).toHaveClass(/active/);
    await expect(page.locator('#status-chips .chip[data-status="all"]')).not.toHaveClass(/active/);

    // Step 4: the stats strip is project-scoped, so a status chip must not move it.
    await expect(page.locator('#s-total')).toHaveText('25');
    await expect(page.locator('#s-done')).toContainText('10');
    await expect(page.locator('#s-flight')).toHaveText(String(FIXTURE.inFlight));
    await expect(page.locator('#p-pct')).toHaveText(`${FIXTURE.donePct}%`);

    // Step 5-6: All brings every column back.
    await page.click('#status-chips .chip[data-status="all"]');
    expect(await visibleColumns(page)).toEqual(ALL_STATUSES);
    expect(await resultCount(page)).toBe('25 of 25 shown');

    // Step 7: Done only.
    await page.click('#status-chips .chip[data-status="done"]');
    expect(await visibleColumns(page)).toEqual(['done']);
    expect(await resultCount(page)).toBe('10 of 25 shown');
    await expect(page.locator('#count-done')).toHaveText('10');

    // A status with no fixture rows still collapses cleanly.
    await page.click('#status-chips .chip[data-status="escalated"]');
    expect(await visibleColumns(page)).toEqual(['escalated']);
    expect(await resultCount(page)).toBe('0 of 25 shown');
    await expect(page.locator('#col-escalated .col-empty')).toHaveText('—');

    await page.click('#status-chips .chip[data-status="all"]');
    expect(errors).toEqual([]);
  });

  // ── TC-06 ──────────────────────────────────────────────────────────────
  test('TC-SB106 filter dimensions combine with AND and clear together', async ({ page }) => {
    const errors = await login(page);

    // Dropdowns are built from the loaded data, not hardcoded (step: "only show
    // values present in current data").
    // Values are the agent names the filter matches on; the visible text also
    // carries the agent icon.
    const agentValues = await page.locator('#agent-filter option')
      .evaluateAll((os) => os.map((o) => o.value));
    expect(agentValues).toEqual(['all', '__unassigned', FIXTURE.agents.one.name, FIXTURE.agents.two.name]);
    const agentText = await page.locator('#agent-filter option').allTextContents();
    expect(agentText[2]).toContain(FIXTURE.agents.one.icon);
    expect(agentText[2]).toContain(FIXTURE.agents.one.name);

    // Order is data order rather than alphabetical; the case only requires that
    // the options be exactly the labels present in the data.
    const labelValues = await page.locator('#label-filter option')
      .evaluateAll((os) => os.map((o) => o.value));
    expect(labelValues[0]).toBe('all');
    expect(labelValues.slice(1).sort()).toEqual(['privacy-review', 'qa-fixture']);

    // Step 1: priority alone.
    await page.selectOption('#priority-filter', 'high');
    const highOnly = Number((await resultCount(page)).split(' ')[0]);
    expect(highOnly).toBeGreaterThan(0);

    // Step 2: + agent. Narrower than priority alone, and never wider.
    await page.selectOption('#agent-filter', FIXTURE.agents.one.name);
    const highPlusAgent = Number((await resultCount(page)).split(' ')[0]);
    expect(highPlusAgent).toBeLessThanOrEqual(highOnly);

    // Every rendered card satisfies both dimensions at once.
    for (const card of await page.locator('.card').all()) {
      await expect(card.locator('.priority-dot')).toHaveClass(/priority-high/);
      await expect(card.locator('.agent-chip')).toContainText(FIXTURE.agents.one.name.split(' ').pop());
    }

    // Step 3-5: + search narrows again, and the count stays truthful.
    await page.fill('#search-input', 'fixture');
    const allThree = Number((await resultCount(page)).split(' ')[0]);
    expect(allThree).toBeLessThanOrEqual(highPlusAgent);
    expect(await page.locator('.card').count()).toBe(allThree);

    // A combination with no members yields an honest zero, not a stale board.
    await page.fill('#search-input', 'zzz-no-such-item');
    expect(await resultCount(page)).toBe('0 of 25 shown');
    expect(await page.locator('.card').count()).toBe(0);

    // Step 6: Clear resets all six dimensions plus search.
    await page.click('#filter-clear');
    expect(await resultCount(page)).toBe('25 of 25 shown');
    await expect(page.locator('#priority-filter')).toHaveValue('all');
    await expect(page.locator('#agent-filter')).toHaveValue('all');
    await expect(page.locator('#label-filter')).toHaveValue('all');
    await expect(page.locator('#flag-filter')).toHaveValue('all');
    await expect(page.locator('#search-input')).toHaveValue('');
    await expect(page.locator('#status-chips .chip[data-status="all"]')).toHaveClass(/active/);
    await expect(page.locator('#domain-chips .chip[data-domain="all"]')).toHaveClass(/active/);

    // Step 7: overdue means due in the past AND not done/on_hold/blocked.
    await page.selectOption('#flag-filter', 'overdue');
    const overdue = Number((await resultCount(page)).split(' ')[0]);
    expect(overdue).toBeGreaterThan(0);
    for (const card of await page.locator('.card').all()) {
      await expect(card.locator('.card-due')).toHaveClass(/overdue/);
    }
    expect(await visibleColumns(page).then((c) => c.includes('done'))).toBe(true);
    expect(await page.locator('#col-done .card').count()).toBe(0);

    // Step 8: label AND flag together.
    await page.selectOption('#label-filter', 'qa-fixture');
    const both = Number((await resultCount(page)).split(' ')[0]);
    expect(both).toBeLessThanOrEqual(overdue);
    for (const card of await page.locator('.card').all()) {
      await expect(card.locator('.card-label', { hasText: 'qa-fixture' })).toBeVisible();
      await expect(card.locator('.card-due')).toHaveClass(/overdue/);
    }

    await page.click('#filter-clear');
    expect(errors).toEqual([]);
  });

  // ── TC-07 ──────────────────────────────────────────────────────────────
  test('TC-SB107 search spans title, description, project, agent and labels', async ({ page }) => {
    const errors = await login(page);

    // Step 1: title fragment.
    await page.fill('#search-input', 'Rich fixture card');
    expect(await page.locator('.card').count()).toBe(1);
    await expect(cardByTitle(page, FIXTURE.cards.rich)).toBeVisible();

    // Step 2: agent name returns everything that agent owns.
    await page.fill('#search-input', FIXTURE.agents.one.name);
    expect(await page.locator('.card').count()).toBe(FIXTURE.agents.one.total);

    // Step 3: label name.
    await page.fill('#search-input', 'privacy-review');
    const byLabel = await page.locator('.card').count();
    expect(byLabel).toBeGreaterThan(0);
    for (const card of await page.locator('.card').all()) {
      await expect(card.locator('.card-label', { hasText: 'privacy-review' })).toBeVisible();
    }

    // Step 4: project name.
    await page.fill('#search-input', FIXTURE.alpha.name);
    expect(await page.locator('.card').count()).toBe(FIXTURE.alpha.total);

    // Description-only match — the field is in the haystack but never rendered
    // on the card, so this is the one dimension a card-text check would miss.
    await page.fill('#search-input', 'all layers');
    expect(await page.locator('.card').count()).toBeGreaterThan(0);

    // Case insensitivity, both directions.
    await page.fill('#search-input', 'RICH FIXTURE CARD');
    expect(await page.locator('.card').count()).toBe(1);
    await page.fill('#search-input', 'rich fixture card');
    expect(await page.locator('.card').count()).toBe(1);

    // Step 5: gibberish.
    await page.fill('#search-input', 'qqqzzzxxx');
    expect(await resultCount(page)).toBe('0 of 25 shown');
    expect(await page.locator('.card').count()).toBe(0);

    // Step 6: clearing restores everything.
    await page.fill('#search-input', '');
    expect(await resultCount(page)).toBe('25 of 25 shown');

    // Search composes with the other filters rather than replacing them.
    await page.click('#status-chips .chip[data-status="done"]');
    await page.fill('#search-input', FIXTURE.agents.one.name);
    const scoped = Number((await resultCount(page)).split(' ')[0]);
    expect(scoped).toBe(await page.locator('#col-done .card').count());
    expect(scoped).toBeLessThan(FIXTURE.agents.one.total);

    await page.click('#filter-clear');
    expect(errors).toEqual([]);
  });

  // ── TC-15 ──────────────────────────────────────────────────────────────
  test('TC-SB115 modal closes via X, Cancel, overlay and Escape', async ({ page }) => {
    const errors = await login(page);
    const overlay = page.locator('#modal-overlay');

    const openEdit = async () => {
      await cardByTitle(page, FIXTURE.cards.rich).click();
      await expect(overlay).toHaveClass(/active/);
      await expect(page.locator('#m-title')).toHaveValue(FIXTURE.cards.rich);
    };

    // Mechanism 1 — the X button.
    await openEdit();
    await page.click('#modal-close');
    await expect(overlay).not.toHaveClass(/active/);
    expect(await page.evaluate(() => window.editingItem ?? null)).toBeNull();

    // Mechanism 2 — Cancel, with an edit typed in first to prove it is dropped.
    await openEdit();
    await page.fill('#m-title', 'edited but never saved');
    await page.click('#btn-cancel-modal');
    await expect(overlay).not.toHaveClass(/active/);

    // Mechanism 3 — clicking the overlay backdrop, not the dialog.
    await openEdit();
    await overlay.click({ position: { x: 5, y: 5 } });
    await expect(overlay).not.toHaveClass(/active/);

    // Clicking inside the dialog must NOT close it.
    await openEdit();
    await page.locator('.modal').click({ position: { x: 10, y: 10 } });
    await expect(overlay).toHaveClass(/active/);

    // Mechanism 4 — Escape.
    await page.keyboard.press('Escape');
    await expect(overlay).not.toHaveClass(/active/);

    // Step 5: nothing was saved. The card still carries its original title, and
    // the stub would have 405'd any write attempt.
    await expect(cardByTitle(page, FIXTURE.cards.rich)).toBeVisible();
    expect(await page.locator('.card').count()).toBe(FIXTURE.total);

    // Reopening starts clean rather than showing the abandoned edit.
    await openEdit();
    await page.keyboard.press('Escape');

    // Create mode closes the same way and leaves no residue.
    await page.click('#btn-new');
    await expect(overlay).toHaveClass(/active/);
    await expect(page.locator('#modal-title')).toHaveText('New Work Item');
    await page.fill('#m-title', 'discarded draft');
    await page.keyboard.press('Escape');
    await expect(overlay).not.toHaveClass(/active/);
    expect(await page.locator('.card').count()).toBe(FIXTURE.total);

    expect(errors).toEqual([]);
  });

  // ── TC-18 ──────────────────────────────────────────────────────────────
  test('TC-SB118 large dataset renders fast and degrades gracefully', async ({ page }) => {
    const bulk = withBulk(PAYLOAD);
    const grandTotal = FIXTURE.total + BULK_TOTALS.total;

    const started = Date.now();
    const errors = await login(page, { payload: bulk, expectTotal: grandTotal });
    const renderMs = Date.now() - started;

    // Step 1: 200+ items (550 here) must paint in under 2s. Measured from the
    // board tab opening to the last card being in the DOM, so it covers
    // filterItems + the innerHTML build, which is what the case is about.
    const scopeStart = Date.now();
    await selectProject(page, 'QA Fixture Bulk');
    await expect(page.locator('#s-total')).toHaveText(String(BULK_TOTALS.total));
    expect(await page.locator('.card').count()).toBe(BULK_TOTALS.total);
    const bulkRenderMs = Date.now() - scopeStart;
    expect(bulkRenderMs).toBeLessThan(2000);
    test.info().annotations.push(
      { type: 'render', description: `full load ${renderMs}ms; bulk re-render ${bulkRenderMs}ms` });

    // Column counts match the seeded (post-trigger) distribution exactly.
    for (const [status, n] of Object.entries(BULK_TOTALS.byStatus)) {
      await expect(page.locator(`#count-${status}`)).toHaveText(String(n));
    }
    await expect(page.locator('#s-unassigned')).toHaveText(String(BULK_TOTALS.unassigned));

    // Step 2: rapid filter toggling leaves no stale state.
    for (let i = 0; i < 3; i++) {
      for (const s of ['backlog', 'todo', 'done', 'all']) {
        await page.click(`#status-chips .chip[data-status="${s}"]`);
      }
      await page.selectOption('#priority-filter', i % 2 ? 'all' : 'high');
    }
    await page.click('#filter-clear');
    expect(await page.locator('.card').count()).toBe(BULK_TOTALS.total);
    expect(await resultCount(page)).toBe(`${BULK_TOTALS.total} of ${BULK_TOTALS.total} shown`);

    // Step 3: an empty project renders its empty state, not a broken board.
    await selectProject(page, FIXTURE.empty.name);
    await expect(page.locator('#s-total')).toHaveText('0');
    await expect(page.locator('#p-pct')).toHaveText('0%');
    expect(await page.locator('.card').count()).toBe(0);
    expect(await page.locator('.col-empty').count()).toBe(ALL_STATUSES.length);

    await selectProject(page, 'QA Fixture Bulk');

    // Step 5: a >200 char title wraps instead of overflowing its card.
    const longCard = cardByTitle(page, 'Bulk edge — very long title');
    expect(EDGE.longTitle.title.length).toBeGreaterThan(200);
    const titleBox = await longCard.locator('.card-title').boundingBox();
    const cardBox = await longCard.boundingBox();
    expect(titleBox.width).toBeLessThanOrEqual(cardBox.width);
    expect(titleBox.height).toBeGreaterThan(20); // wrapped to several lines

    // Step 6: an item with no description, due date, labels or agent.
    const bare = cardByTitle(page, EDGE.bare.title);
    await expect(bare).toBeVisible();
    expect(await bare.locator('.card-label').count()).toBe(0);
    expect(await bare.locator('.card-due').count()).toBe(0);
    expect(await bare.locator('.card-comments').count()).toBe(0);
    await expect(bare.locator('.agent-chip')).toHaveClass(/unassigned/);

    // Step 7: compliance detected from the title.
    await expect(cardByTitle(page, EDGE.complianceTitle.title).locator('.compliance-badge')).toBeVisible();
    // Step 8: and from a label, on a card whose title is clean.
    const byLabel = cardByTitle(page, EDGE.complianceLabel.title);
    await expect(byLabel.locator('.compliance-badge')).toBeVisible();
    await expect(byLabel.locator('.card-label')).toHaveText('license-check');

    // The compliance flag filter agrees with the badges it renders.
    await page.selectOption('#flag-filter', 'compliance');
    const flagged = await page.locator('.card').count();
    expect(await page.locator('.card .compliance-badge').count()).toBe(flagged);
    await page.click('#filter-clear');

    // Step 4 + expected: nothing NaN/undefined/null leaked into the UI.
    const stats = await page.locator('#stats-strip').innerText();
    expect(stats).not.toMatch(/NaN|undefined|null/);
    const board = await page.locator('#board').innerText();
    expect(board).not.toMatch(/NaN|undefined|null/);

    expect(errors).toEqual([]);
  });

  // ── TC-16 ──────────────────────────────────────────────────────────────
  // Deliberately not run. Every assertion in this case is about the real
  // Supabase auth session: that one token is shared across dashboard tabs, that
  // signing out of JARVIS signs out the board, that RLS scopes rows to the
  // owner, and that an expired token degrades gracefully. Under the stub the
  // session object is something this suite fabricates, so "verifying" any of
  // that would only be asserting that the stub returns what the stub was told
  // to return. Recorded as blocked, not passed — see TC-SB116-V1 in test_cases.
  test.skip('TC-SB116 auth session sharing with the JARVIS dashboard', () => {});

  // ── TC-19 ──────────────────────────────────────────────────────────────
  test('TC-SB119 board tab integrates into the JARVIS dashboard', async ({ page }) => {
    const errors = await login(page, { skipBoard: true });

    // Step 2: the board tab is present in the dashboard nav.
    const tab = page.locator('.g-tab[data-tab="board"]');
    await expect(tab).toBeVisible();
    const tabLabel = (await tab.textContent()).trim();

    // Step 6: the shared dark theme.
    const bg = await page.evaluate(() =>
      getComputedStyle(document.documentElement).getPropertyValue('--bg').trim());
    expect(bg).toBe('#0d1117');

    // Step 3: clicking loads the board in-place — no navigation.
    const urlBefore = page.url();
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
    expect(page.url().split('#')[0]).toBe(urlBefore.split('#')[0]);

    // Step 4: the hash tracks the active tab.
    const hash = await page.evaluate(() => window.location.hash);

    // Step 7: the board header carries no second brand/login — the shell owns them.
    expect(await page.locator('#panel-board .brand').count()).toBe(0);
    await expect(page.locator('#login-overlay')).toHaveClass(/hidden/);

    // Step 8: away and back preserves the loaded data without a refetch.
    await page.click('.g-tab[data-tab="jarvis"]');
    await expect(page.locator('#panel-board')).not.toHaveClass(/active/);
    await openBoard(page);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));
    expect(await page.locator('.card').count()).toBe(FIXTURE.total);

    // Step 5: a deep link restores the tab on reload.
    await page.goto(`/jarvis-dashboard.html${hash}`);
    await expect(page.locator('#panel-board')).toHaveClass(/active/, { timeout: 20000 });
    await expect(page.locator('.g-tab[data-tab="board"]')).toHaveClass(/active/);

    expect(errors).toEqual([]);

    // The case names a "Kanban" tab at #kanban; the app ships "Board" at #board.
    // Asserted last so the substantive integration checks above are all recorded
    // before this trips.
    expect({ label: tabLabel, hash }).toEqual({ label: 'Kanban', hash: '#kanban' });
  });
});
