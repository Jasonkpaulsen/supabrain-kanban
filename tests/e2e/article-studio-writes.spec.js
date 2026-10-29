// SB-634 / SB-636: Article Studio counts a write as done only when the database says so.
//
// SB-634: updates and deletes filtered out by RLS return no rows and no error, so patch(), the
// article deletes and createArticle used to report success for writes that changed nothing; a
// lapsed session left an empty list; there was no sign-out. SB-636: changing the header image
// was three separate writes, and Save/Reject read CURRENT after an await.
//
// Stubbed backend (article-studio-stub.js); options make a write match nothing or fail.
const { test, expect } = require('@playwright/test');
const { openStudio, toast, deletesOf, deleteLibraryImage, openTrashedArticle, A1, EXPECTED_HTTP } = require('./article-studio-stub');

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

  test('TC-SB634-03g a session that ends closes the new-article sheet', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => openNewArticle());
    await expect(page.locator('#newSheet')).toHaveClass(/open/);
    await page.evaluate(() => sb.auth.signOut({ scope: 'local' }));
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#newSheet')).not.toHaveClass(/open/);
  });

  test('TC-SB634-03h a load still running at sign-out draws nothing afterwards', async ({ page }) => {
    await openStudio(page);
    let release;
    const held = new Promise((res) => { release = res; });
    await page.route('**/rest/v1/articles?*', async (r) => {
      if (r.request().method() !== 'GET') return r.fallback();
      await held;
      return r.fallback();
    });
    await page.locator('button.ref:has-text("↻")').click();
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    release();
    await page.waitForTimeout(500);
    expect(await page.evaluate(() => ARTICLES.length)).toBe(0);
    for (const id of ['#tabs', '#stats', '#recs', '#list']) await expect(page.locator(id)).toBeEmpty();
  });

  test('TC-SB634-03i signing out clears the calendar and library and returns to the board', async ({ page }) => {
    await openStudio(page);
    await page.click('#n-lib');
    await expect(page.locator('#libGrid .card').first()).toBeVisible();
    await page.click('#n-cal');
    await expect(page.locator('#agenda')).not.toBeEmpty();
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#login')).toHaveCSS('display', 'flex');
    for (const id of ['#agenda', '#libGrid', '#purgedList', '#tabs', '#stats']) await expect(page.locator(id)).toBeEmpty();
    await expect(page.locator('#n-board')).toHaveClass(/on/);
  });

  test('TC-SB634-03j a session check refused by the server online shows the login screen', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => { sb.auth.getSession = async () => ({ data: { session: null }, error: Object.assign(new Error('Invalid Refresh Token'), { name: 'AuthApiError', status: 400 }) }); });
    await page.locator('button.ref:has-text("↻")').click();
    await expect(page.locator('#login')).toBeVisible();
    await expect(page.locator('#loginErr')).toHaveText('Session ended — sign in again');
    await expect(page.locator('#offline')).toBeHidden();
  });

  test('TC-SB634-03k offline: a failed session check shows the banner; the next good load hides it', async ({ page }) => {
    await openStudio(page);
    await page.evaluate(() => {
      window.__gs = sb.auth.getSession.bind(sb.auth);
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
      sb.auth.getSession = async () => ({ data: { session: null }, error: new Error('Failed to fetch') });
    });
    await page.locator('button.ref:has-text("↻")').click();
    await expect(page.locator('#offline')).toBeVisible();
    await expect(page.locator('#app')).toBeVisible();
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true }); sb.auth.getSession = window.__gs; });
    await page.locator('button.ref:has-text("↻")').click();
    await expect(page.locator('#offline')).toBeHidden();
  });

  test('TC-SB634-03l a library or purged-list load still running at sign-out draws nothing', async ({ page }) => {
    await openStudio(page);
    let release;
    const held = new Promise((res) => { release = res; });
    await page.route('**/rest/v1/{image_assets,lce_deletion_log}?*', async (r) => {
      if (r.request().method() !== 'GET') return r.fallback();
      await held;
      return r.fallback();
    });
    await page.click('#n-lib');
    await page.click('#n-purged');
    await page.locator('#signOut').click();
    await expect(page.locator('#login')).toBeVisible();
    release();
    await page.waitForTimeout(500);
    await expect(page.locator('#libGrid')).toBeEmpty();
    await expect(page.locator('#purgedList')).toBeEmpty();
  });

  test('TC-SB634-03m signing in again starts on all articles, not the last filter', async ({ page }) => {
    await openStudio(page);
    await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
    await page.locator('#signOut').click();
    await page.fill('#password', 'stubbed');
    await page.click('button:has-text("Enter Studio")');
    await expect(page.locator('#app')).toBeVisible();
    expect(await page.evaluate(() => FILTER)).toBe('all');
  });

  test('TC-SB634-03n offline with a stored session keeps the banner when the load fails', async ({ page }) => {
    await openStudio(page);
    await page.route('**/rest/v1/articles?*', (r) => (r.request().method() === 'GET' ? r.abort('internetdisconnected') : r.fallback()));
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false }); window.dispatchEvent(new Event('offline')); });
    await expect(page.locator('#offline')).toBeVisible();
    await page.locator('button.ref:has-text("↻")').click();
    await page.waitForTimeout(500);
    await expect(page.locator('#offline')).toBeVisible();
  });

  test('TC-SB636-03c a header change that finishes after another article was opened leaves that sheet alone', async ({ page }) => {
    await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await expect(page.locator('#imgZone')).toContainText('img i2');
    let release;
    const held = new Promise((res) => { release = res; });
    await page.route('**/rest/v1/rpc/set_article_header', async (r) => {
      if (r.request().method() !== 'POST') return r.fallback();
      await held;
      return r.fallback();
    });
    await page.locator('#imgZone .imgcard', { hasText: 'img i1' }).locator('button:has-text("Accept")').click();
    await page.evaluate(() => closeSheet());
    await openTrashedArticle(page, 'Trashed two');
    await expect(page.locator('#imgZone')).toContainText('img i3');
    release();
    await page.waitForTimeout(700);
    await expect(page.locator('#imgZone')).toContainText('img i3');
    await expect(page.locator('#imgZone')).not.toContainText('img i2');
    await expect(page.locator('#imgZone .hero')).toHaveCount(0);
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

  // SB-643: a library image used as a header is copied; the library keeps it, and its file.
  async function useSaved(page, description) {
    await page.locator('button:has-text("Use saved")').click();
    await page.locator('#libPick .imgcard', { hasText: description }).locator('img').click();
    await expect(toast(page)).toHaveText('Set as header');
  }
  const LIB1 = 'lce-images/library/saved-1.png';

  test('TC-SB643-03a Use saved leaves the image in the library', async ({ page }) => {
    const { db } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await useSaved(page, 'img lib1');
    await expect(page.locator('#imgZone .hero img')).toHaveAttribute('src', `https://x.test/${LIB1}`);
    const lib1 = db.images.find((i) => i.id === 'lib1');
    expect([lib1.status, lib1.article_id]).toEqual(['saved', null]);
    expect(db.images.filter((i) => i.storage_path === LIB1).map((i) => [i.status, i.article_id])).toEqual([['saved', null], ['accepted', A1]]);
    await page.evaluate(() => closeSheet());
    await page.click('#n-lib');
    await expect(page.locator('#libGrid .card', { hasText: 'img lib1' })).toBeVisible();
  });

  test('TC-SB643-03b removing an article whose header is a copy keeps the library image and its file', async ({ page }) => {
    const { calls, db, errors } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await useSaved(page, 'img lib1');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.storage.flat()).not.toContain(LIB1);
    expect(db.files.has(LIB1)).toBe(true);
    expect(db.images.filter((i) => i.storage_path === LIB1).map((i) => i.id)).toEqual(['lib1']);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB643-03c deleting a library image whose copy is a header keeps the file', async ({ page }) => {
    const { calls, db } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await useSaved(page, 'img lib1');
    await page.evaluate(() => closeSheet());
    await deleteLibraryImage(page, 'img lib1');
    await expect(page.locator('#libGrid .card', { hasText: 'img lib1' })).toHaveCount(0);
    expect(calls.storage.flat()).not.toContain(LIB1);
    expect(db.files.has(LIB1)).toBe(true);
    expect(db.images.filter((i) => i.storage_path === LIB1).map((i) => [i.status, i.article_id])).toEqual([['accepted', A1]]);
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
