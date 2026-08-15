// QA batch 3/3 — SB-341. Mutating CRUD, comments, drag-drop and the
// cross-feature integration path.
//
// Two-sided by necessity. This file is the CLIENT half: it drives the real UI
// against a write-capable stub and asserts both the rendered result and the
// exact PostgREST call the app put on the wire. The DATABASE half — that
// Postgres accepts the write, that the trigger stack reshapes it as expected,
// that FK cascades fire — cannot be reached from this runner (no egress) and is
// verified separately by SQL against the live project. Neither half alone is
// the test; test_runs records which assertions came from which.
const { test, expect } = require('@playwright/test');
const { FIXTURE, openBoard, cardByTitle } = require('./fixture');
const { installWriteStubs, requestsFor } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

// Same login path as batches 1-2, but wired to the mutating backend.
async function loginWritable(page) {
  if (!EMAIL || !PASSWORD) {
    throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
  }
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  const backend = await installWriteStubs(page);
  await page.goto('/jarvis-dashboard.html');
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-btn');
  await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
  await openBoard(page);
  await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total), { timeout: 20000 });
  return { backend, errors };
}

const toast = (page) => page.locator('.toast, #toast').last();

test.describe('@batch3 SB-341', () => {
  // ── TC-10 ──────────────────────────────────────────────────────────────
  test('TC-SB110 create a work item through the modal', async ({ page }) => {
    const { backend, errors } = await loginWritable(page);

    // Step 1-2: create mode opens with the documented defaults.
    await page.click('#btn-new');
    await expect(page.locator('#modal-overlay')).toHaveClass(/active/);
    await expect(page.locator('#modal-title')).toHaveText('New Work Item');
    await expect(page.locator('#m-title')).toHaveValue('');
    await expect(page.locator('#m-desc')).toHaveValue('');
    await expect(page.locator('#m-status')).toHaveValue('backlog');
    await expect(page.locator('#m-priority')).toHaveValue('medium');
    await expect(page.locator('#m-assignee')).toHaveValue('');
    await expect(page.locator('#m-due')).toHaveValue('');
    expect(await page.locator('#m-labels .label-chip.selected').count()).toBe(0);

    // Step 3-4: delete button and comments are hidden in create mode.
    await expect(page.locator('#btn-delete-item')).toBeHidden();
    await expect(page.locator('#comments-section')).toBeHidden();

    // Validation: an empty title must not save.
    await page.click('#btn-save-modal');
    await expect(toast(page)).toContainText('Title is required');
    await expect(page.locator('#modal-overlay')).toHaveClass(/active/);
    expect(requestsFor(backend, 'POST', '/work_items').length).toBe(0);

    // Step 5-7: fill everything, pick two labels, save.
    await page.fill('#m-title', 'Batch3 created item');
    await page.fill('#m-desc', 'Created by TC-SB110.');
    await page.selectOption('#m-status', 'todo');
    await page.selectOption('#m-priority', 'high');
    await page.fill('#m-assignee', 'Jason Paulsen');
    await page.fill('#m-due', '2026-09-30');
    const chips = page.locator('#m-labels .label-chip');
    await chips.nth(0).click();
    await chips.nth(1).click();
    await page.click('#btn-save-modal');

    await expect(toast(page)).toContainText('Created');
    await expect(page.locator('#modal-overlay')).not.toHaveClass(/active/);

    // Step 8: the card lands in the right column with its fields.
    const card = cardByTitle(page, 'Batch3 created item');
    await expect(card).toBeVisible();
    expect(await page.locator('#col-todo .card').filter({ hasText: 'Batch3 created item' }).count()).toBe(1);
    await expect(card.locator('.priority-dot')).toHaveClass(/priority-high/);
    await expect(card.locator('.card-due')).toContainText('2026-09-30');
    expect(await card.locator('.card-label').count()).toBe(2);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total + 1));

    // Step 9 (client half): the wire call carries exactly what was entered.
    const posts = requestsFor(backend, 'POST', '/rest/v1/work_items');
    expect(posts.length).toBe(1);
    expect(posts[0].body).toMatchObject({
      title: 'Batch3 created item', description: 'Created by TC-SB110.',
      status: 'todo', priority: 'high', assignee: 'Jason Paulsen', due_date: '2026-09-30',
    });
    // Label sync: unlink-then-link, two links for the two chips.
    const labelPosts = requestsFor(backend, 'POST', '/work_item_labels');
    expect(labelPosts.length).toBe(1);
    expect(labelPosts[0].body).toHaveLength(2);

    // Validation: title only, everything else null.
    await page.click('#btn-new');
    await page.fill('#m-title', 'Batch3 minimal item');
    await page.click('#btn-save-modal');
    await expect(toast(page)).toContainText('Created');
    await expect(cardByTitle(page, 'Batch3 minimal item')).toBeVisible();
    const minimal = requestsFor(backend, 'POST', '/rest/v1/work_items')[1];
    expect(minimal.body).toMatchObject({ title: 'Batch3 minimal item', description: null, assignee: null, due_date: null });
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total + 2));

    expect(errors).toEqual([]);
  });

  // ── TC-11 ──────────────────────────────────────────────────────────────
  test('TC-SB111 edit an existing work item through the modal', async ({ page }) => {
    const { backend, errors } = await loginWritable(page);

    // Step 1-2: edit mode pre-fills from the card.
    await cardByTitle(page, FIXTURE.cards.rich).click();
    await expect(page.locator('#modal-overlay')).toHaveClass(/active/);
    await expect(page.locator('#m-title')).toHaveValue(FIXTURE.cards.rich);
    const originalStatus = await page.locator('#m-status').inputValue();
    const originalPriority = await page.locator('#m-priority').inputValue();
    expect(originalStatus).toBeTruthy();
    expect(originalPriority).toBeTruthy();

    // Step 3: the item's own labels come back selected.
    const selectedBefore = await page.locator('#m-labels .label-chip.selected').count();
    expect(selectedBefore).toBe(2);

    // Step 4-5: delete button and comments are visible in edit mode.
    await expect(page.locator('#btn-delete-item')).toBeVisible();
    await expect(page.locator('#comments-section')).toBeVisible();

    // Step 6-7: change title, drop a label, change priority, save.
    await page.fill('#m-title', 'Rich fixture card — edited');
    await page.locator('#m-labels .label-chip.selected').first().click();
    await page.selectOption('#m-priority', 'critical');
    await page.click('#btn-save-modal');

    // Step 8-9: modal closes and the card re-renders with the new values.
    // The toast text is captured here but asserted at the very end, so this
    // case's remaining assertions are all exercised before it trips.
    await expect(page.locator('#modal-overlay')).not.toHaveClass(/active/);
    const saveToast = (await toast(page).textContent()).trim();
    const card = cardByTitle(page, 'Rich fixture card — edited');
    await expect(card).toBeVisible();
    await expect(card.locator('.priority-dot')).toHaveClass(/priority-critical/);
    expect(await card.locator('.card-label').count()).toBe(1);
    // Editing must not create a row.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));

    // Step 10 (client half): PATCH targets the right row and carries the edit,
    // and the label sync is delete-then-insert as the case describes.
    const patches = requestsFor(backend, 'PATCH', '/rest/v1/work_items');
    expect(patches.length).toBe(1);
    expect(patches[0].body).toMatchObject({ title: 'Rich fixture card — edited', priority: 'critical' });
    expect(patches[0].body.updated_at).toBeTruthy();
    expect(requestsFor(backend, 'DELETE', '/work_item_labels').length).toBe(1);
    expect(requestsFor(backend, 'POST', '/work_item_labels')[0].body).toHaveLength(1);

    // Reopening shows the persisted values rather than the pre-edit ones.
    await cardByTitle(page, 'Rich fixture card — edited').click();
    await expect(page.locator('#m-title')).toHaveValue('Rich fixture card — edited');
    await expect(page.locator('#m-priority')).toHaveValue('critical');
    expect(await page.locator('#m-labels .label-chip.selected').count()).toBe(1);
    await page.keyboard.press('Escape');

    expect(errors).toEqual([]);

    // Step 8: the case requires the success toast to read "Updated" on an edit.
    // It reads "Created". btn-save-modal calls closeModal() before the toast,
    // and closeModal() sets editingItem = null — so the ternary
    // `toast(editingItem ? 'Updated' : 'Created')` can never take its first
    // branch. An application defect, not spec drift.
    expect(saveToast).toBe('Updated');
  });

  // ── TC-12 ──────────────────────────────────────────────────────────────
  test('TC-SB112 delete a work item behind a confirmation', async ({ page }) => {
    const { backend, errors } = await loginWritable(page);

    await cardByTitle(page, FIXTURE.cards.rich).click();
    await expect(page.locator('#btn-delete-item')).toBeVisible();

    // Step 2-3: dismissing the confirm must delete nothing and keep the modal.
    page.once('dialog', (d) => d.dismiss());
    await page.click('#btn-delete-item');
    await expect(page.locator('#modal-overlay')).toHaveClass(/active/);
    expect(requestsFor(backend, 'DELETE', '/rest/v1/work_items').length).toBe(0);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));

    // Step 4-5: accepting deletes.
    let dialogMessage = '';
    page.once('dialog', (d) => { dialogMessage = d.message(); d.accept(); });
    await page.click('#btn-delete-item');
    await expect(toast(page)).toContainText('Deleted');
    expect(dialogMessage).toContain('Delete this work item?');
    await expect(page.locator('#modal-overlay')).not.toHaveClass(/active/);

    // Step 6-7: card gone, stats down by one.
    await expect(cardByTitle(page, FIXTURE.cards.rich)).toHaveCount(0);
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total - 1));

    // Step 8 (client half): one DELETE, aimed at that row.
    const deletes = requestsFor(backend, 'DELETE', '/rest/v1/work_items');
    expect(deletes.length).toBe(1);
    expect(deletes[0].url).toContain('id=eq.');

    expect(errors).toEqual([]);
  });

  // ── TC-13 ──────────────────────────────────────────────────────────────
  test('TC-SB113 comments load, display and add', async ({ page }) => {
    const { backend, errors } = await loginWritable(page);

    // Step 7 first: a card with no comments shows the empty state.
    await cardByTitle(page, FIXTURE.cards.bare).click();
    await expect(page.locator('#comments-section')).toBeVisible();
    await expect(page.locator('#comments-list')).toContainText('No comments yet');

    // Empty body is a no-op — no request, no phantom comment.
    await page.fill('#comment-input', '   ');
    await page.click('#btn-add-comment');
    expect(requestsFor(backend, 'POST', '/work_item_comments').length).toBe(0);
    await expect(page.locator('#comments-list')).toContainText('No comments yet');

    // Step 3-4: add one, and it appears in the list.
    await page.fill('#comment-input', 'First comment from TC-SB113.');
    await page.click('#btn-add-comment');
    await expect(page.locator('.comment').first()).toContainText('First comment from TC-SB113.');
    await expect(page.locator('#comment-input')).toHaveValue('');

    // Newest first: the second comment must land above the first.
    await page.fill('#comment-input', 'Second comment, newer.');
    await page.click('#btn-add-comment');
    await expect(page.locator('.comment')).toHaveCount(2);
    await expect(page.locator('.comment').first()).toContainText('Second comment, newer.');
    await expect(page.locator('.comment').nth(1)).toContainText('First comment from TC-SB113.');
    // Each comment renders a timestamp alongside its body.
    expect(await page.locator('.comment .comment-date').count()).toBe(2);

    // A long comment wraps inside its box rather than overflowing.
    await page.fill('#comment-input', 'x'.repeat(400));
    await page.click('#btn-add-comment');
    await expect(page.locator('.comment')).toHaveCount(3);
    const box = await page.locator('.comment').first().boundingBox();
    const bodyBox = await page.locator('.comment .comment-body').first().boundingBox();
    expect(bodyBox.width).toBeLessThanOrEqual(box.width + 1);

    // Step 5-6: the card's comment count reflects the additions.
    await page.keyboard.press('Escape');
    await expect(cardByTitle(page, FIXTURE.cards.bare).locator('.card-comments')).toContainText('3');

    // Client half: three POSTs, each carrying the item id and body.
    const posts = requestsFor(backend, 'POST', '/work_item_comments');
    expect(posts.length).toBe(3);
    expect(posts[0].body).toMatchObject({ body: 'First comment from TC-SB113.' });
    expect(posts[0].body.work_item_id).toBeTruthy();

    expect(errors).toEqual([]);
  });

  // ── TC-14 ──────────────────────────────────────────────────────────────
  test('TC-SB114 drag and drop moves cards between columns', async ({ page }) => {
    const { backend, errors } = await loginWritable(page);

    const backlogBefore = Number(await page.locator('#count-backlog').textContent());
    const todoBefore = Number(await page.locator('#count-todo').textContent());
    const card = page.locator('#col-backlog .card').first();
    const title = await card.locator('.card-title').textContent();

    // Step 2: HTML5 drag has no Playwright primitive that fires the app's own
    // handlers, so dispatch the real event sequence and assert the visual
    // feedback the case names between the steps.
    await card.dispatchEvent('dragstart', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(card).toHaveClass(/dragging/);
    // .card carries `transition: all 0.15s`, so sample after it settles rather
    // than mid-tween.
    await expect
      .poll(() => card.evaluate((el) => getComputedStyle(el).opacity))
      .toBe('0.5');

    const target = page.locator('.column[data-status="todo"]');
    await target.dispatchEvent('dragover', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(target).toHaveClass(/drag-over/);

    // dragleave onto a child must not clear the highlight (the case's flicker
    // edge case) — the handler guards with column.contains(relatedTarget).
    await target.dispatchEvent('dragleave', {
      relatedTarget: await target.locator('.column-body').elementHandle(),
    });
    await expect(target).toHaveClass(/drag-over/);

    // Step 3-5: drop.
    await target.dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(toast(page)).toContainText('Moved to todo');
    await expect(target).not.toHaveClass(/drag-over/);
    await expect(page.locator('#count-backlog')).toHaveText(String(backlogBefore - 1));
    await expect(page.locator('#count-todo')).toHaveText(String(todoBefore + 1));
    expect(await page.locator('#col-todo .card').filter({ hasText: title.trim() }).count()).toBe(1);

    // Step 6: the stats strip follows the move (in-flight gains the todo item).
    await expect(page.locator('#s-flight')).toHaveText(String(FIXTURE.inFlight + 1));
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.total));

    // Step 8 (client half): the RPC, with the documented argument names.
    const rpc = requestsFor(backend, 'POST', '/rpc/move_work_item');
    expect(rpc.length).toBe(1);
    expect(rpc[0].body).toMatchObject({ p_new_status: 'todo' });
    expect(rpc[0].body.p_item_id).toBeTruthy();
    expect(typeof rpc[0].body.p_new_sort_order).toBe('number');

    // Step 7: a move to Done stamps completed_at and shifts the delivery bar.
    const doneBefore = Number(await page.locator('#count-done').textContent());
    const moved = page.locator('#col-todo .card').filter({ hasText: title.trim() }).first();
    await moved.dispatchEvent('dragstart', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    const doneCol = page.locator('.column[data-status="done"]');
    await doneCol.dispatchEvent('dragover', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await doneCol.dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(toast(page)).toContainText('Moved to done');
    await expect(page.locator('#count-done')).toHaveText(String(doneBefore + 1));
    const movedRow = backend.state.items.find((i) => i.title.trim() === title.trim());
    expect(movedRow.completed_at).toBeTruthy();

    // Edge case: dropping onto the card's current column stays a no-op visually.
    const rpcBefore = requestsFor(backend, 'POST', '/rpc/move_work_item').length;
    const same = page.locator('#col-done .card').filter({ hasText: title.trim() }).first();
    await same.dispatchEvent('dragstart', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await doneCol.dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(page.locator('#count-done')).toHaveText(String(doneBefore + 1));

    expect(errors).toEqual([]);

    // Every drop must issue exactly ONE move_work_item RPC. It does not.
    //
    // bindCardEvents() runs at the end of every renderBoard(), and while .card
    // elements are rebuilt each render (so their listeners are replaced), the
    // .column elements are static markup — so each render stacks another
    // dragover/dragleave/drop listener onto every column. The Nth drop of a
    // session therefore fires N identical RPCs: N database writes, N trigger
    // runs, N activity_log rows for one user gesture.
    //
    // Measured in this run: 1st drop 1 RPC, 2nd 2, 3rd 3, 4th 4 — exactly the
    // accumulation the leak predicts. Asserted last so the case's behavioural
    // steps are all recorded first. Application defect, not spec drift.
    const rpcForThisDrop = requestsFor(backend, 'POST', '/rpc/move_work_item').length - rpcBefore;
    expect(rpcForThisDrop).toBe(1);
  });

  // ── TC-17 ──────────────────────────────────────────────────────────────
  test('TC-SB117 filters, stats and drag-drop stay consistent', async ({ page }) => {
    const { errors } = await loginWritable(page);

    // Step 1-3: scoping to a project narrows stats and the agent panel together.
    const pill = page.locator(`.proj-pill[title="${FIXTURE.alpha.name}"]`);
    const value = await pill.getAttribute('data-id');
    await pill.click();
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.alpha.total));
    await expect(page.locator('#s-done')).toContainText(String(FIXTURE.alpha.done));
    const utilCards = await page.locator('#util-grid .agent-card').count();
    expect(utilCards).toBeGreaterThan(0);

    // Step 4-6: a drag inside the filtered view moves every dependent number.
    const doneBefore = Number(await page.locator('#count-done').textContent());
    const flightBefore = Number(await page.locator('#s-flight').textContent());
    const pctBefore = await page.locator('#p-pct').textContent();

    const card = page.locator('#col-in_progress .card').first();
    await card.dispatchEvent('dragstart', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    const doneCol = page.locator('.column[data-status="done"]');
    await doneCol.dispatchEvent('dragover', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await doneCol.dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });

    await expect(toast(page)).toContainText('Moved to done');
    await expect(page.locator('#count-done')).toHaveText(String(doneBefore + 1));
    await expect(page.locator('#s-flight')).toHaveText(String(flightBefore - 1));
    await expect(page.locator('#p-pct')).not.toHaveText(pctBefore);
    // Total is unchanged — a move is not a create.
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.alpha.total));

    // Step 7-9: with a status chip active, a move out of the shown status makes
    // the card leave the filtered view, and All brings it back in its new column.
    await page.click('#status-chips .chip[data-status="in_progress"]');
    const shown = page.locator('#col-in_progress .card');
    const before = await shown.count();
    expect(before).toBeGreaterThan(0);
    const moving = shown.first();
    const movingTitle = (await moving.locator('.card-title').textContent()).trim();
    await moving.dispatchEvent('dragstart', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    const reviewCol = page.locator('.column[data-status="review"]');
    await reviewCol.dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => new DataTransfer()) });
    await expect(toast(page)).toContainText('Moved to review');
    await expect(shown).toHaveCount(before - 1);
    expect(await page.locator('.card').filter({ hasText: movingTitle }).count()).toBe(0);

    await page.click('#status-chips .chip[data-status="all"]');
    expect(await page.locator('#col-review .card').filter({ hasText: movingTitle }).count()).toBe(1);

    // The stats strip stays project-scoped and ignores the status chip, while
    // the board reads from the fully filtered set.
    await page.click('#status-chips .chip[data-status="done"]');
    await expect(page.locator('#s-total')).toHaveText(String(FIXTURE.alpha.total));

    expect(errors).toEqual([]);
  });
});
