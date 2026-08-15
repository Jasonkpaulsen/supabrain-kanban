// SB-339 — QA batch 1/3: static render & analytics surfaces.
// Covers TC-SB101, TC-SB102, TC-SB103, TC-SB104, TC-SB108, TC-SB109.
//
// Every test in this batch is read-only: no test writes to the database. The
// one interaction that opens a modal (TC-09 step 6) closes it without saving.
const { test, expect } = require('@playwright/test');
const {
  FIXTURE, SPEC_COLUMNS, login, selectProject, selectAllProjects, cardByTitle,
} = require('./fixture');

let consoleErrors = [];

test.beforeEach(async ({ page }) => {
  consoleErrors = await login(page);
});

// Each test case asserts "no console errors" as its final step.
test.afterEach(() => {
  expect(consoleErrors, `console errors: ${consoleErrors.join(' | ')}`).toEqual([]);
});

/* ───────────────────────── TC-SB101-V1 — stats strip ───────────────────────── */
test('@batch1 TC-SB101 stats strip renders correct counts', async ({ page }) => {
  // Steps 2-5: all-projects totals.
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));
  await expect(page.locator('#s-flight')).toHaveText(String(FIXTURE.inFlight));
  await expect(page.locator('#s-unassigned')).toHaveText(String(FIXTURE.unassigned));

  // Done renders as "<count> <pct>" with the percentage in a nested <small>.
  const doneCount = await page.locator('#s-done').evaluate((el) => el.firstChild.textContent.trim());
  expect(doneCount).toBe(String(FIXTURE.byStatus.done));
  await expect(page.locator('#s-done-pct')).toHaveText(`${FIXTURE.donePct}%`);
  await expect(page.locator('#p-pct')).toHaveText(`${FIXTURE.donePct}%`);

  // Expected: percentage rounds cleanly — no NaN, no decimals.
  const pct = await page.locator('#p-pct').textContent();
  expect(pct).toMatch(/^\d+%$/);

  // Steps 6-7: single-project scoping.
  for (const p of [FIXTURE.alpha, FIXTURE.beta]) {
    await selectProject(page, p.name);
    await expect(page.locator('#s-total')).toHaveText(String(p.total));
    await expect(page.locator('#s-flight')).toHaveText(String(p.inFlight));
    await expect(page.locator('#s-unassigned')).toHaveText(String(p.unassigned));
    await expect(page.locator('#s-done-pct')).toHaveText(`${p.donePct}%`);
  }

  // Expected/zero state: a project with no items shows 0 / 0% and does not throw.
  await selectProject(page, FIXTURE.empty.name);
  await expect(page.locator('#s-total')).toHaveText('0');
  await expect(page.locator('#s-flight')).toHaveText('0');
  await expect(page.locator('#s-unassigned')).toHaveText('0');
  await expect(page.locator('#s-done-pct')).toHaveText('0%');

  await selectAllProjects(page);
});

/* ──────────────────── TC-SB102-V1 — delivery progress bar ──────────────────── */
test('@batch1 TC-SB102 delivery progress bar segments are proportional', async ({ page }) => {
  // Steps 2-3: seeded 10 done / 5 review / 3 in_progress of 25 => 40 / 20 / 12 %.
  const width = (id) => page.locator(`#${id}`).evaluate((el) => el.style.width);
  expect(await width('seg-done')).toBe(FIXTURE.segments.done);
  expect(await width('seg-review')).toBe(FIXTURE.segments.review);
  expect(await width('seg-prog')).toBe(FIXTURE.segments.prog);

  // Step 4: legend swatches match the segment colours.
  const segColor = (sel) => page.locator(sel).evaluate((el) => getComputedStyle(el).backgroundColor);
  const legend = page.locator('.progress-legend i');
  expect(await segColor('#seg-done')).toBe(await legend.nth(0).evaluate((el) => getComputedStyle(el).backgroundColor));
  expect(await segColor('#seg-review')).toBe(await legend.nth(1).evaluate((el) => getComputedStyle(el).backgroundColor));
  expect(await segColor('#seg-prog')).toBe(await legend.nth(2).evaluate((el) => getComputedStyle(el).backgroundColor));

  // Steps 5-6: the bar recomputes without a page reload. Batch 1 is read-only,
  // so reactivity is driven by a project filter change rather than the
  // drag-and-drop of the original step — drag-drop is covered by TC-SB114.
  // The browser rounds inline percentage widths to 6 significant figures, so
  // compare numerically here rather than as a string.
  await selectProject(page, FIXTURE.alpha.name);
  expect(parseFloat(await width('seg-done')))
    .toBeCloseTo((FIXTURE.alpha.done / FIXTURE.alpha.total) * 100, 3);
  await selectAllProjects(page);
  expect(await width('seg-done')).toBe(FIXTURE.segments.done);

  // Edge case: no items => empty bar, no division by zero.
  await selectProject(page, FIXTURE.empty.name);
  for (const id of ['seg-done', 'seg-review', 'seg-prog']) {
    expect(await width(id)).toBe('0%');
  }
  await expect(page.locator('#p-pct')).toHaveText('0%');

  await selectAllProjects(page);
});

/* ───────────────────── TC-SB103-V1 — domain breakdown card ─────────────────── */
test('@batch1 TC-SB103 domain breakdown card shows project-based grouping', async ({ page }) => {
  const rows = page.locator('#domain-rows .domain-row');

  // Steps 2-3: one row per domain that has items, with matching counts.
  const counts = {};
  for (const row of await rows.all()) {
    counts[(await row.locator('.nm').textContent()).trim()] =
      Number((await row.locator('.ct').textContent()).trim());
  }
  expect(counts).toEqual(FIXTURE.domains);

  // Expected: sum of domain counts equals total items.
  const sum = Object.values(counts).reduce((a, b) => a + b, 0);
  expect(sum).toBe(FIXTURE.total);

  // Every row carries a colour dot.
  await expect(rows.locator('.dot')).toHaveCount(Object.keys(FIXTURE.domains).length);

  // Steps 4-5: filtering to one project collapses the card to that domain.
  await selectProject(page, FIXTURE.alpha.name);
  await expect(rows).toHaveCount(1);
  await expect(rows.first().locator('.nm')).toHaveText('products');
  await expect(rows.first().locator('.ct')).toHaveText(String(FIXTURE.alpha.total));

  // Zero-item project: the card degrades to an explicit empty state.
  await selectProject(page, FIXTURE.empty.name);
  await expect(rows).toHaveCount(0);
  await expect(page.locator('#domain-rows')).toContainText('No items');

  await selectAllProjects(page);
});

/* ──────────────────── TC-SB104-V1 — agent utilization panel ────────────────── */
test('@batch1 TC-SB104 agent utilization panel renders and toggles', async ({ page }) => {
  const panel = page.locator('#util-panel');
  const toggle = page.locator('#btn-util');
  const { agents } = FIXTURE;

  // The panel ships open, so step 1 is asserted as a close/open round trip
  // (step 6 collapses it again at the end).
  await expect(panel).toHaveClass(/open/);

  // Step 2: summary bar.
  const summary = page.locator('#util-summary');
  await expect(summary).toContainText(`${agents.count} agents`);
  await expect(summary).toContainText(`${agents.owned} owned`);
  await expect(summary).toContainText(`${agents.open} open`);
  await expect(summary).toContainText(`${agents.donePct}% done`);
  await expect(summary).toContainText(`${FIXTURE.unassigned} unassigned`);

  // Step 3: agent cards sorted by most open work first; the tie between two
  // 5-open agents breaks on total owned, so Agent One (10) precedes Two (9).
  const named = page.locator('.agent-card:not(.unassigned-card)');
  await expect(named).toHaveCount(agents.count);
  await expect(named.nth(0).locator('.ac-name')).toHaveText(agents.one.name);
  await expect(named.nth(1).locator('.ac-name')).toHaveText(agents.two.name);

  // Step 4: per-card anatomy.
  const one = named.nth(0);
  await expect(one.locator('.ac-av')).toHaveText(agents.one.icon);
  await expect(one.locator('.ac-status')).toHaveText('active');
  await expect(one.locator('.ac-load .n')).toHaveText(String(agents.one.open));
  await expect(one.locator('.ac-load .lbl')).toHaveText(
    `open / cap ${agents.one.cap} · ${agents.one.total} total · ${agents.one.done} done`
  );
  await expect(one.locator('.ac-bar span').first()).toBeVisible();
  await expect(one.locator('.ac-metrics div').nth(0)).toContainText(agents.one.runs);
  await expect(one.locator('.ac-metrics div').nth(2)).toContainText(agents.one.avg);
  await expect(one.locator('.ac-metrics div').nth(3)).toContainText('ago');

  // Edge case: error_count > 0 renders red (class "err").
  await expect(one.locator('.ac-metrics b.err')).toHaveText(agents.one.errors);

  // Edge cases: null avg_duration_ms shows "—", null last_run_at shows "never",
  // and a zero error count is not flagged red.
  const two = named.nth(1);
  await expect(two.locator('.ac-load .lbl')).toHaveText(
    `open / cap ${agents.two.cap} · ${agents.two.total} total · ${agents.two.done} done`
  );
  await expect(two.locator('.ac-metrics div').nth(2)).toContainText(agents.two.avg);
  await expect(two.locator('.ac-metrics div').nth(3)).toContainText(agents.two.last);
  await expect(two.locator('.ac-metrics b.err')).toHaveCount(0);

  // Step 5: unassigned card, dashed border, correct count.
  const gap = page.locator('.agent-card.unassigned-card');
  await expect(gap).toHaveCount(1);
  await expect(gap.locator('.ac-load .n')).toHaveText(String(FIXTURE.unassigned));
  expect(await gap.evaluate((el) => getComputedStyle(el).borderStyle)).toContain('dashed');

  // Step 7: filtering to one project leaves only agents holding tickets there.
  await selectProject(page, FIXTURE.alpha.name);
  await expect(named).toHaveCount(1);
  await expect(named.first().locator('.ac-name')).toHaveText(agents.one.name);
  await selectProject(page, FIXTURE.beta.name);
  await expect(named).toHaveCount(1);
  await expect(named.first().locator('.ac-name')).toHaveText(agents.two.name);

  // Edge case: a view with no assigned agents falls back to an empty state.
  await selectProject(page, FIXTURE.empty.name);
  await expect(named).toHaveCount(0);
  await expect(page.locator('.util-empty')).toBeVisible();
  await selectAllProjects(page);

  // Step 6: toggling collapses the panel, and toggling again restores it.
  await toggle.click();
  await expect(panel).not.toHaveClass(/open/);
  await expect(toggle).not.toHaveClass(/active/);
  await toggle.click();
  await expect(panel).toHaveClass(/open/);
});

/* ─────────────────────── TC-SB108-V1 — card visual layers ──────────────────── */
test('@batch1 TC-SB108 cards render all 5 visual layers correctly', async ({ page }) => {
  const rich = cardByTitle(page, FIXTURE.cards.rich);
  await expect(rich).toBeVisible();

  // Layer 1: 4px domain stripe, coloured by the project's domain.
  const stripe = rich.locator('.domain-stripe');
  expect(await stripe.evaluate((el) => getComputedStyle(el).width)).toBe('4px');
  expect(await stripe.evaluate((el) => getComputedStyle(el).backgroundColor))
    .toBe(FIXTURE.domainStripe.products);

  // Layer 2: meta row — priority dot, project tag, compliance badge.
  await expect(rich.locator('.priority-dot.priority-high')).toHaveCount(1);
  expect(await rich.locator('.priority-dot').evaluate((el) => getComputedStyle(el).backgroundColor))
    .toBe('rgb(210, 153, 34)');
  await expect(rich.locator('.card-project-tag')).toBeVisible();
  await expect(rich.locator('.compliance-badge')).toBeVisible();

  // Layer 3: label chips carry the colours stored on the label rows.
  const labels = rich.locator('.card-label');
  await expect(labels).toHaveCount(2);
  for (const chip of await labels.all()) {
    const name = (await chip.textContent()).trim();
    expect(await chip.evaluate((el) => getComputedStyle(el).backgroundColor))
      .toBe(FIXTURE.labelColors[name]);
  }

  // Layer 4: title typography.
  const title = rich.locator('.card-title');
  expect(await title.evaluate((el) => getComputedStyle(el).fontSize)).toBe('14px');
  expect(await title.evaluate((el) => getComputedStyle(el).fontWeight)).toBe('500');

  // Layer 5: footer — overdue due date, comment count, agent chip.
  await expect(rich.locator('.card-due.overdue')).toBeVisible();
  await expect(rich.locator('.card-comments')).toContainText('2');
  const chip = rich.locator('.agent-chip');
  await expect(chip.locator('.av')).toHaveText(FIXTURE.agents.one.icon);
  await expect(chip).toContainText(FIXTURE.agents.one.name);

  // Edge cases on a deliberately bare card: no labels row, no due date, no
  // comment count, dashed "Unassigned" chip.
  const bare = cardByTitle(page, FIXTURE.cards.bare);
  await expect(bare.locator('.card-labels')).toHaveCount(0);
  await expect(bare.locator('.card-due')).toHaveCount(0);
  await expect(bare.locator('.card-comments')).toHaveCount(0);
  const unassignedChip = bare.locator('.agent-chip.unassigned');
  await expect(unassignedChip).toHaveText(/Unassigned/);
  expect(await unassignedChip.evaluate((el) => getComputedStyle(el).borderStyle)).toContain('dashed');

  // Edge case: a very long title wraps onto multiple lines instead of clipping.
  const longTitle = cardByTitle(page, FIXTURE.cards.longTitle).locator('.card-title');
  const box = await longTitle.boundingBox();
  expect(box.height).toBeGreaterThan(30);
  expect(await longTitle.evaluate((el) => el.scrollWidth <= el.clientWidth + 1)).toBe(true);

  // Step 7: project tags disappear in single-project view.
  await selectProject(page, FIXTURE.alpha.name);
  await expect(page.locator('.card-project-tag')).toHaveCount(0);
  await selectAllProjects(page);
  expect(await page.locator('.card-project-tag').count()).toBeGreaterThan(0);
});

/* ────────────────────────── TC-SB109-V1 — columns ──────────────────────────── */
test('@batch1 TC-SB109 8 columns render with correct colors and counts', async ({ page }) => {
  const columns = page.locator('.column');

  // Steps 2-3: the eight named columns render, in order, with the specified
  // header colours and count badges.
  for (const col of SPEC_COLUMNS) {
    const el = page.locator(`.column[data-status="${col.status}"]`);
    await expect(el).toBeVisible();
    await expect(el.locator('.column-title')).toHaveText(col.title);
    expect(await el.locator('.column-title').evaluate((e) => getComputedStyle(e).color)).toBe(col.color);
    await expect(page.locator(`#count-${col.status}`)).toHaveText(String(FIXTURE.byStatus[col.status]));
  }

  const order = await columns.evaluateAll((els) => els.map((e) => e.dataset.status));
  expect(order).toEqual(SPEC_COLUMNS.map((c) => c.status));

  // Step 4: columns with no items show the "—" placeholder.
  for (const status of ['on_hold', 'blocked', 'escalated']) {
    await expect(page.locator(`#col-${status} .col-empty`)).toHaveText('—');
  }

  // Step 5: every column offers "+ Add card".
  await expect(page.locator('.add-card-btn')).toHaveCount(order.length);

  // Expected: 300px min-width and a viewport-derived max height.
  const first = columns.first();
  expect(await first.evaluate((el) => getComputedStyle(el).minWidth)).toBe('300px');
  const viewportH = page.viewportSize().height;
  expect(await first.evaluate((el) => getComputedStyle(el).maxHeight)).toBe(`${viewportH - 240}px`);

  // Expected: cards are ordered by sort_order inside a column.
  const reviewTitles = await page.locator('#col-review .card-title').allTextContents();
  expect(reviewTitles).toEqual([
    'Alpha review one', 'Alpha review two', 'Beta review one', 'Beta review two', 'Beta review three',
  ]);

  // Step 7: a column body scrolls independently of the board.
  expect(await page.locator('#col-done').evaluate((el) => getComputedStyle(el).overflowY)).toBe('auto');

  // Step 6: "+ Add card" on In Progress opens the modal with the status
  // pre-selected. Closed immediately without saving — batch 1 writes nothing.
  await page.locator('.add-card-btn[data-status="in_progress"]').click();
  await expect(page.locator('#modal-overlay')).toHaveClass(/active/);
  await expect(page.locator('#m-status')).toHaveValue('in_progress');
  await page.locator('#modal-close').click();
  await expect(page.locator('#modal-overlay')).not.toHaveClass(/active/);

  // Step 1: the board carries all eight work_item statuses (rev 2, SB-342).
  await expect(columns).toHaveCount(SPEC_COLUMNS.length);
});
