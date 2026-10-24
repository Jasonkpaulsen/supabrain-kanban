// SB-631 (TC-SB631-01..05): Article Studio removes an image row only when its file went.
//
// deleteStorage used to check r.ok alone. The Storage API answers 200 with an empty list when
// nothing matched, so a removal that removed nothing looked done, and destroy, emptyTrash and
// deleteImage then removed the image_assets rows anyway, leaving the files in project-assets
// with nothing pointing at them (and, after SB-627, no way for the user to remove them).
//
// Stubbed backend, as in cards.spec.js: auth and the vendored supabase-js come from stub.js's
// conventions; REST and Storage are a small stateful stub defined here. Each test sets what the
// Storage DELETE reports as removed, then asserts the writes the page sent.
const { test, expect } = require('@playwright/test');
const { SESSION } = require('./stub');

const SUPABASE_UMD = require.resolve('@supabase/supabase-js/dist/umd/supabase.js');
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': '*',
  'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
};

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64');
const A1 = '11111111-1111-4111-8111-111111111111';
const A2 = '22222222-2222-4222-8222-222222222222';
const now = new Date().toISOString();
const article = (id, title) => ({ id, title, status: 'trashed', updated_at: now, created_at: now, body_md: '', feedback_history: [] });
const image = (id, path, articleId, status = 'candidate') =>
  ({ id, storage_path: path, article_id: articleId, status, description: `img ${id}`, public_url: `https://x.test/${path}`, sort_order: 0, updated_at: now });

function seed() {
  return {
    articles: [article(A1, 'Trashed one'), article(A2, 'Trashed two')],
    images: [
      image('i1', `lce-images/${A1}/candidate-1.png`, A1),
      image('i2', `lce-images/${A1}/candidate-2.png`, A1),
      image('i3', `lce-images/${A2}/candidate-1.png`, A2),
      image('lib1', 'lce-images/library/saved-1.png', null, 'saved'),
      image('nofile', null, null, 'saved'),
    ],
  };
}

// Minimal PostgREST filters used by the page: col=eq.v, col=in.(a,b).
function filterRows(url, rows) {
  const q = new URL(url).searchParams;
  return rows.filter((r) => {
    for (const [k, v] of q) {
      if (['select', 'order', 'limit', 'offset'].includes(k)) continue;
      const m = /^(eq|in)\.(.*)$/.exec(v);
      if (!m) continue;
      const val = r[k] == null ? 'null' : String(r[k]);
      if (m[1] === 'eq' && val !== m[2]) return false;
      if (m[1] === 'in' && !m[2].replace(/^\(|\)$/g, '').split(',').map((s) => s.replace(/"/g, '')).includes(val)) return false;
    }
    return true;
  });
}

async function openStudio(page, { removes = () => [], storageStatus = 200, storageAbort = false } = {}) {
  const db = seed();
  const calls = { storage: [], deletes: [], logs: [] };
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => d.accept());

  await page.route('**/cdn.jsdelivr.net/**', (r) => r.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD }));
  // Thumbnails point at a fixture host; serve a 1x1 PNG so they load instead of logging errors.
  await page.route('https://x.test/**', (r) => r.fulfill({ status: 200, contentType: 'image/png', body: PNG }));
  await page.route('**/auth/v1/**', (r) => {
    const u = r.request().url();
    const body = u.includes('/token') ? SESSION : u.includes('/user') ? SESSION.user : {};
    return r.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify(body) });
  });
  await page.route('**/storage/v1/object/project-assets', async (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    const asked = JSON.parse(req.postData() || '{}').prefixes || [];
    calls.storage.push(asked);
    if (storageAbort) return r.abort('failed');
    if (storageStatus !== 200) return r.fulfill({ status: storageStatus, headers: CORS, contentType: 'application/json', body: '{"message":"boom"}' });
    const gone = asked.filter((p) => removes(p));
    return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json',
      body: JSON.stringify(gone.map((name) => ({ name, bucket_id: 'project-assets' }))) });
  });
  await page.route('**/rest/v1/**', async (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    const url = req.url();
    const table = new URL(url).pathname.split('/').pop();
    const rows = table === 'articles' ? db.articles : table === 'image_assets' ? db.images : [];
    if (req.method() === 'GET') {
      const out = filterRows(url, rows);
      const single = (req.headers()['accept'] || '').includes('vnd.pgrst.object');
      return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify(single ? out[0] || null : out) });
    }
    if (req.method() === 'DELETE') {
      const hit = filterRows(url, rows);
      calls.deletes.push({ table, ids: hit.map((x) => x.id) });
      if (table === 'articles') db.articles = db.articles.filter((x) => !hit.includes(x));
      if (table === 'image_assets') db.images = db.images.filter((x) => !hit.includes(x));
      return r.fulfill({ status: 204, headers: CORS, body: '' });
    }
    if (req.method() === 'POST' && table === 'lce_deletion_log') {
      calls.logs.push(...JSON.parse(req.postData() || '[]'));
      return r.fulfill({ status: 201, headers: CORS, body: '' });
    }
    return r.fulfill({ status: 405, headers: CORS, contentType: 'application/json', body: '{"message":"not stubbed"}' });
  });

  await page.goto('/article-studio/index.html');
  await page.fill('#email', 'qa-fixture@supabrain.test');
  await page.fill('#password', 'stubbed');
  await page.click('button:has-text("Enter Studio")');
  await expect(page.locator('#app')).toBeVisible();
  return { calls, errors, db };
}

const toast = (page) => page.locator('#toast');
const deletesOf = (calls, table) => calls.deletes.filter((d) => d.table === table);

async function deleteLibraryImage(page, description) {
  await page.click('#n-lib');
  const card = page.locator('#libGrid .card', { hasText: description });
  await expect(card).toBeVisible();
  await card.locator('button:has-text("Delete")').click();
}

async function openTrashedArticle(page, title) {
  await page.click('#n-board');
  await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
  await page.locator('.card', { hasText: title }).first().click();
  await expect(page.locator('#sheet')).toHaveClass(/open/);
}

test.describe('@sb631 Article Studio removals', () => {
  // sw.js would fetch thumbnails itself, outside page.route; the worker is not under test.
  test.use({ serviceWorkers: 'block' });

  test('TC-SB631-01 library image: a removal that removed nothing keeps the row', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { removes: () => false });
    await deleteLibraryImage(page, 'img lib1');
    await expect(toast(page)).toHaveText('File not removed — image kept');
    expect(calls.storage).toEqual([['lce-images/library/saved-1.png']]);
    expect(calls.deletes).toEqual([]);
    expect(calls.logs).toEqual([]);
    await expect(page.locator('#libGrid .card', { hasText: 'img lib1' })).toBeVisible();
    expect(errors).toEqual([]);
  });

  test('TC-SB631-02 library image: a real removal removes the row and logs it', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { removes: () => true });
    await deleteLibraryImage(page, 'img lib1');
    await expect(toast(page)).toHaveText('Deleted');
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['lib1'] }]);
    expect(calls.logs).toEqual([expect.objectContaining({ entity_type: 'image', entity_id: 'lib1', storage_path: 'lce-images/library/saved-1.png', reason: 'manual_delete' })]);
    await expect(page.locator('#libGrid .card', { hasText: 'img lib1' })).toHaveCount(0);
    expect(errors).toEqual([]);
  });

  test('TC-SB631-03 article in Trash: the article and its unremoved image are kept', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page, { removes: (p) => p.endsWith('candidate-1.png') });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('1 file(s) not removed — article kept in Trash');
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['i1'] }]);
    expect(deletesOf(calls, 'articles')).toEqual([]);
    expect(calls.logs).toEqual([]);
    expect(db.articles.map((a) => a.id)).toContain(A1);
    expect(db.images.map((i) => i.id)).toContain('i2');
    expect(errors).toEqual([]);
  });

  test('TC-SB631-04 Empty Trash: only articles whose files all went are removed', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { removes: (p) => !p.endsWith('candidate-2.png') });
    await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
    await page.locator('button:has-text("Empty Trash")').click();
    await expect(toast(page)).toHaveText('Purged 1, kept 1 — 1 file(s) not removed');
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['i1', 'i3'] }]);
    expect(deletesOf(calls, 'articles')).toEqual([{ table: 'articles', ids: [A2] }]);
    expect(calls.logs).toEqual([expect.objectContaining({ entity_type: 'article', entity_id: A2, reason: 'manual_empty_trash' })]);
    expect(errors).toEqual([]);
  });

  test('TC-SB631-05a a Storage error or network failure removes nothing', async ({ page }) => {
    for (const opts of [{ storageStatus: 500 }, { storageAbort: true }]) {
      const ctx = await page.context().browser().newContext();
      const p = await ctx.newPage();
      const { calls } = await openStudio(p, opts);
      await deleteLibraryImage(p, 'img lib1');
      await expect(toast(p)).toHaveText('File not removed — image kept');
      expect(calls.storage.length).toBe(1);
      expect(calls.deletes).toEqual([]);
      expect(calls.logs).toEqual([]);
      await ctx.close();
    }
  });

  test('TC-SB631-05b an image with no file is removed without a Storage call', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { removes: () => false });
    await deleteLibraryImage(page, 'img nofile');
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.storage).toEqual([]);
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['nofile'] }]);
    expect(errors).toEqual([]);
  });
});
