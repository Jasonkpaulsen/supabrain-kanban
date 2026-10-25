// SB-634 / SB-636: Article Studio counts a write as done only when the database says so.
//
// SB-634: updates and deletes filtered out by RLS return no rows and no error, so patch(), the
// article deletes and createArticle used to report success for writes that changed nothing; a
// lapsed session left an empty list; there was no sign-out. SB-636: changing the header image
// was three separate writes, and Save/Reject read CURRENT after an await.
//
// Stubbed backend (article-studio-stub.js); options make a write match nothing or fail.
const { test, expect } = require('@playwright/test');
const { openStudio, toast, deletesOf, openTrashedArticle, A1, EXPECTED_HTTP } = require('./article-studio-stub');

const NOT_SAVED = 'Not saved — this article changed or is no longer yours';
const now = new Date().toISOString();

async function openDraft(page, db) {
  db.articles.push({ id: 'd1', title: 'Draft one', status: 'draft', body_md: 'Hello', updated_at: now, created_at: now, feedback_history: [] });
  await page.locator('button.ref:has-text("↻")').click();
  await page.locator("[onclick=\"setFilter('draft')\"]").first().click();
  await page.locator('.card', { hasText: 'Draft one' }).first().click();
  await expect(page.locator('#sheet')).toHaveClass(/open/);
}

test.describe('@sb634 @sb636 Article Studio writes', () => {
  test.use({ serviceWorkers: 'block' });

  test('TC-SB634-01a an update that matched no row says Not saved', async ({ page }) => {
    const { calls, db, errors } = await openStudio(page, { noopPatch: true });
    await openDraft(page, db);
    await page.locator('#sheetActions button:has-text("Trash")').click();
    await expect(toast(page)).toHaveText(NOT_SAVED);
    expect(calls.patches).toEqual([expect.objectContaining({ table: 'articles', ids: [] })]);
    expect(db.articles.find((a) => a.id === 'd1').status).toBe('draft');
    await expect(page.locator('#sheet')).toHaveClass(/open/);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB634-01b saving the body that matched no row says Not saved', async ({ page }) => {
    const { db } = await openStudio(page, { noopPatch: true });
    await openDraft(page, db);
    await page.locator('#segEdit').click();
    await page.fill('#body', 'Changed text');
    await page.locator('button:has-text("Save text")').click();
    await expect(toast(page)).toHaveText(NOT_SAVED);
  });

  test('TC-SB634-01c control: an update that lands reports success', async ({ page }) => {
    const { calls, db } = await openStudio(page);
    await openDraft(page, db);
    await page.locator('#sheetActions button:has-text("Trash")').click();
    await expect(toast(page)).toHaveText('Moved to trash');
    expect(calls.patches[0].ids).toEqual(['d1']);
  });

  test('TC-SB634-01d a create that returned no row says so', async ({ page }) => {
    await openStudio(page, { noopInsert: true });
    await page.locator('button[title="New Article"]').click();
    await page.fill('#newTitle', 'New one');
    await page.locator('button:has-text("Create Draft")').click();
    await expect(toast(page)).toHaveText('Draft not created');
  });

  test('TC-SB634-02a an article delete that removed nothing logs no article', async ({ page }) => {
    const { calls } = await openStudio(page, { noopArticleDelete: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Article not removed — it changed or is no longer yours');
    expect(calls.logs.filter((l) => l.entity_type === 'article')).toEqual([]);
    expect(calls.logs.map((l) => l.entity_id).sort()).toEqual(['i1', 'i2']);
  });

  test('TC-SB634-02b Empty Trash logs only the articles the delete returned', async ({ page }) => {
    const { calls } = await openStudio(page, { noopArticleDelete: true });
    await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
    await page.locator('button:has-text("Empty Trash")').click();
    await expect(toast(page)).toHaveText('Purged 0, kept 2');
    expect(calls.logs.filter((l) => l.entity_type === 'article')).toEqual([]);
  });

  test('TC-SB634-02d Empty Trash whose lookup fails says so, not "already empty"', async ({ page }) => {
    const { calls } = await openStudio(page);
    await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
    await page.route('**/rest/v1/articles?*status=eq.trashed*', (r) => (r.request().method() === 'GET'
      ? r.fulfill({ status: 503, headers: { 'access-control-allow-origin': '*' }, contentType: 'application/json', body: '{"message":"article lookup down"}' })
      : r.fallback()));
    await page.locator('button:has-text("Empty Trash")').click();
    await expect(toast(page)).toHaveText('article lookup down');
    expect(calls.deletes).toEqual([]);
  });

  test('TC-SB634-02c image rows the delete did not return keep the article and are not logged', async ({ page }) => {
    const { calls, db } = await openStudio(page, { noopImageDelete: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('2 file(s) not removed — article kept in Trash');
    expect(deletesOf(calls, 'articles')).toEqual([]);
    expect(calls.logs).toEqual([]);
    expect(db.articles.map((a) => a.id)).toContain(A1);
  });

  test('TC-SB634-03a Sign out returns to the login screen', async ({ page }) => {
    const { calls } = await openStudio(page);
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#app')).toBeHidden();
    expect(calls.logouts).toBe(1);
  });

  test('TC-SB634-03b a session that ends (SIGNED_OUT) returns to the login screen', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => sb.auth.signOut({ scope: 'local' }));
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#loginErr')).toHaveText('Signed out — sign in again');
  });

  test('TC-SB634-03c reloading with no session shows the login screen, not an empty list', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => { sb.auth.getSession = async () => ({ data: { session: null }, error: null }); });
    await page.locator('button.ref:has-text("↻")').click();
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#loginErr')).toHaveText('Session ended — sign in again');
  });

  test('TC-SB634-03d signing out clears the password and closes the open article', async ({ page }) => {
    const { db } = await openStudio(page);
    await openDraft(page, db);
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#password')).toHaveValue('');
    await expect(page.locator('#sheet')).not.toHaveClass(/open/);
    await expect(page.locator('#sheetBody')).toBeEmpty();
    await expect(page.getByText('Draft one')).toHaveCount(0);
    // signing in again shows the articles again
    await page.fill('#password', 'stubbed');
    await page.click('button:has-text("Enter Studio")');
    await expect(page.locator('#app')).toBeVisible();
    await page.locator("[onclick=\"setFilter('draft')\"]").first().click();
    await expect(page.locator('.card', { hasText: 'Draft one' })).toBeVisible();
  });

  test('TC-SB634-03e a session check that fails for the network shows offline, not the login screen', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => { sb.auth.getSession = async () => ({ data: { session: null }, error: Object.assign(new Error('Failed to fetch'), { name: 'AuthRetryableFetchError' }) }); });
    await page.locator('button.ref:has-text("↻")').click();
    await expect(page.locator('#offline')).toBeVisible();
    await expect(page.locator('#app')).toBeVisible();
    await expect(page.locator('#login')).toBeHidden();
  });

  test('TC-SB634-03f coming back online on the login screen loads nothing and keeps the message', async ({ page }) => {
    await openStudio(page);
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    const gets = [];
    page.on('request', (q) => { if (q.method() === 'GET' && q.url().includes('/rest/v1/')) gets.push(q.url()); });
    await page.evaluate(() => { document.getElementById('loginErr').textContent = 'Wrong password'; window.dispatchEvent(new Event('online')); });
    await page.waitForTimeout(300);
    await expect(page.locator('#loginErr')).toHaveText('Wrong password');
    await expect(page.locator('#login')).toBeVisible();
    expect(gets).toEqual([]);
  });

  test('TC-SB636-02a Accept goes through set_article_header once', async ({ page }) => {
    const { calls, db, errors } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('.imgcard', { hasText: 'img i1' }).locator('button:has-text("Accept")').click();
    await expect(toast(page)).toHaveText('Set as header');
    expect(calls.rpc).toEqual([{ p_article_id: A1, p_image_id: 'i1' }]);
    expect(calls.patches.filter((p) => p.table === 'image_assets')).toEqual([]);
    expect(db.articles.find((a) => a.id === A1).image_asset_id).toBe('i1');
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB636-02b a failed header change says so and changes nothing', async ({ page }) => {
    const { calls, db } = await openStudio(page, { rpcError: 'boom' });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('.imgcard', { hasText: 'img i1' }).locator('button:has-text("Accept")').click();
    await expect(toast(page)).toHaveText('Header not changed: boom');
    expect(calls.rpc.length).toBe(1);
    expect(calls.patches).toEqual([]);
    expect(db.articles.find((a) => a.id === A1).image_asset_id).toBeUndefined();
  });

  test('TC-SB636-02c Use saved goes through set_article_header with the library image', async ({ page }) => {
    const { calls } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('button:has-text("Use saved")').click();
    await page.locator('#libPick .imgcard', { hasText: 'img lib1' }).locator('img').click();
    await expect(toast(page)).toHaveText('Set as header');
    expect(calls.rpc).toEqual([{ p_article_id: A1, p_image_id: 'lib1' }]);
    expect(calls.patches).toEqual([]);
  });

  test('TC-SB636-03a Reject with the sheet closed meanwhile does not throw', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { patchDelayMs: 400 });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('.imgcard', { hasText: 'img i1' }).locator('button:has-text("Reject")').click();
    await page.evaluate(() => closeSheet());
    await expect(toast(page)).toHaveText('Rejected');
    expect(calls.patches).toEqual([expect.objectContaining({ table: 'image_assets', ids: ['i1'] })]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB636-03b Save that matched no row says so', async ({ page }) => {
    await openStudio(page, { noopImagePatch: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('.imgcard', { hasText: 'img i2' }).locator('button:has-text("Save")').click();
    await expect(toast(page)).toHaveText('Not saved — this image changed or is no longer yours');
  });
});
