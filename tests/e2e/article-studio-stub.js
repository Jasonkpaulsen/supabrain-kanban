// Shared stub for the Article Studio specs (SB-631, SB-633, SB-634, SB-635, SB-636).
//
// Serves the vendored supabase-js in place of the CDN and stubs auth, REST, the header RPC and
// Storage with a small stateful backend. Every write is recorded in `calls`; options make a
// write fail, or match nothing (RLS hides a row without an error), so specs can assert exactly
// what the page sent and what it told the user.
const { expect } = require('@playwright/test');
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
  ({ id, storage_path: path, storage_bucket: 'project-assets', article_id: articleId, status, description: `img ${id}`, public_url: `https://x.test/${path}`, sort_order: 0, updated_at: now });

function seed() {
  return {
    articles: [article(A1, 'Trashed one'), article(A2, 'Trashed two')],
    images: [
      image('i1', `lce-images/${A1}/candidate-1.png`, A1),
      image('i2', `lce-images/${A1}/candidate-2.png`, A1),
      image('i3', `lce-images/${A2}/candidate-1.png`, A2),
      image('lib1', 'lce-images/library/saved-1.png', null, 'saved'),
      image('nofile', null, null, 'saved'),
      // SB-633: images saved to the library from a trashed article stay when the article goes
      image('sv', `lce-images/${A1}/saved.png`, A1, 'saved'),
      image('lb', `lce-images/${A2}/library.png`, A2, 'library'),
      // two rows on one path, as analyze-image leaves after a re-upload
      image('dupA', 'lce-images/library/dup.png', null, 'saved'),
      image('dupB', 'lce-images/library/dup.png', null, 'saved'),
      image('spaced', 'lce-images/library/with space+plus?.png', null, 'saved'),
    ],
  };
}

// Minimal PostgREST filters used by the page: col=eq.v, col=in.(a,b).
function filterRows(url, rows) {
  const q = new URL(url).searchParams;
  return rows.filter((r) => {
    for (const [k, v] of q) {
      if (['select', 'order', 'limit', 'offset'].includes(k)) continue;
      const m = /^(not\.)?(eq|in)\.(.*)$/.exec(v);
      if (!m) continue;
      const val = r[k] == null ? 'null' : String(r[k]);
      const hit = m[2] === 'eq' ? val === m[3]
        : m[3].replace(/^\(|\)$/g, '').split(',').map((s) => s.replace(/"/g, '')).includes(val);
      if (m[1] ? hit : !hit) return false;
    }
    return true;
  });
}

// removes(path): whether the Storage DELETE may take that file (false models a file RLS hides).
// Files are state: a removed file is gone for good, and HEAD on its public URL then answers 400.
async function openStudio(page, { removes = () => true, storageStatus = 200, storageAbort = false, failImageDeletes = 0, failImageGet = false, head = null, failLog = false, failArticleDelete = false, failSharedLookup = false,
    noopArticleDelete = false, noopPatch = false, noopImagePatch = false, rpcError = null, noopInsert = false, patchDelayMs = 0, noopImageDelete = false } = {}) {
  const db = seed();
  db.files = new Set(db.images.map((i) => i.storage_path).filter(Boolean));
  const calls = { storage: [], deletes: [], logs: [], heads: [], patches: [], rpc: [], inserts: [], logouts: 0 };
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => d.accept());

  await page.route('**/cdn.jsdelivr.net/**', (r) => r.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD }));
  // Thumbnails point at a fixture host; serve a 1x1 PNG so they load instead of logging errors.
  await page.route('https://x.test/**', (r) => r.fulfill({ status: 200, contentType: 'image/png', body: PNG }));
  await page.route('**/auth/v1/**', (r) => {
    const u = r.request().url();
    if (u.includes('/logout')) { calls.logouts += 1; return r.fulfill({ status: 204, headers: CORS, body: '' }); }
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
    const gone = [...new Set(asked)].filter((p) => db.files.has(p) && removes(p));
    gone.forEach((p) => db.files.delete(p));
    return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json',
      body: JSON.stringify(gone.map((name) => ({ name, bucket_id: 'project-assets' }))) });
  });
  await page.route('**/storage/v1/object/public/project-assets/**', (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    const path = decodeURIComponent(new URL(req.url()).pathname.split('/storage/v1/object/public/project-assets/')[1]);
    calls.heads.push(path);
    if (head === 'abort') return r.abort('failed');
    if (head) return r.fulfill({ status: head, headers: CORS, body: '' });
    // storage-api answers 400 {"statusCode":"404"} for a missing public object
    return db.files.has(path)
      ? r.fulfill({ status: 200, headers: CORS, contentType: 'image/png', body: '' })
      : r.fulfill({ status: 400, headers: CORS, contentType: 'application/json', body: '{"statusCode":"404","error":"not_found"}' });
  });
  // SB-636: the header RPC, applied to the stub's rows as the database function would.
  await page.route('**/rest/v1/rpc/set_article_header', async (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    const args = JSON.parse(req.postData() || '{}');
    calls.rpc.push(args);
    if (rpcError) return r.fulfill({ status: 400, headers: CORS, contentType: 'application/json', body: JSON.stringify({ message: rpcError }) });
    let demoted = 0;
    db.images.forEach((i) => { if (i.article_id === args.p_article_id && i.status === 'accepted' && i.id !== args.p_image_id) { i.status = 'saved'; demoted += 1; } });
    const img = db.images.find((i) => i.id === args.p_image_id);
    img.status = 'accepted'; img.article_id = args.p_article_id;
    db.articles.find((a) => a.id === args.p_article_id).image_asset_id = args.p_image_id;
    return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify({ ok: true, demoted }) });
  });
  await page.route('**/rest/v1/**', async (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    if (new URL(req.url()).pathname.includes('/rpc/')) return r.fallback();
    const url = req.url();
    const table = new URL(url).pathname.split('/').pop();
    const rows = table === 'articles' ? db.articles : table === 'image_assets' ? db.images : [];
    if (req.method() === 'GET') {
      if (failSharedLookup && table === 'image_assets' && /storage_path=/.test(url)) {
        return r.fulfill({ status: 503, headers: CORS, contentType: 'application/json', body: '{"message":"shared lookup down"}' });
      }
      if (failImageGet && table === 'image_assets' && /article_id=/.test(url)) {
        return r.fulfill({ status: 503, headers: CORS, contentType: 'application/json', body: '{"message":"lookup down"}' });
      }
      const out = filterRows(url, rows);
      const single = (req.headers()['accept'] || '').includes('vnd.pgrst.object');
      return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify(single ? out[0] || null : out) });
    }
    if (req.method() === 'DELETE') {
      if (table === 'image_assets' && failImageDeletes > 0) {
        failImageDeletes -= 1;
        calls.deletes.push({ table, ids: [], failed: true });
        return r.fulfill({ status: 503, headers: CORS, contentType: 'application/json', body: '{"message":"row delete down"}' });
      }
      if (table === 'articles' && failArticleDelete) {
        return r.fulfill({ status: 503, headers: CORS, contentType: 'application/json', body: '{"message":"article delete down"}' });
      }
      // SB-634: RLS hides a row without an error; the delete then returns no rows.
      const hit = (table === 'articles' && noopArticleDelete) || (table === 'image_assets' && noopImageDelete) ? [] : filterRows(url, rows);
      calls.deletes.push({ table, ids: hit.map((x) => x.id) });
      if (table === 'articles') db.articles = db.articles.filter((x) => !hit.includes(x));
      if (table === 'image_assets') db.images = db.images.filter((x) => !hit.includes(x));
      return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify(hit.map((x) => ({ id: x.id }))) });
    }
    if (req.method() === 'PATCH') {
      if (patchDelayMs) await new Promise((res) => setTimeout(res, patchDelayMs));
      const patch = JSON.parse(req.postData() || '{}');
      const hit = (table === 'articles' && noopPatch) || (table === 'image_assets' && noopImagePatch) ? [] : filterRows(url, rows);
      hit.forEach((x) => Object.assign(x, patch));
      calls.patches.push({ table, ids: hit.map((x) => x.id), patch });
      return r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify(hit.map((x) => ({ id: x.id }))) });
    }
    if (req.method() === 'POST' && table === 'articles') {
      const row = JSON.parse(req.postData() || '{}');
      calls.inserts.push({ table, row });
      if (noopInsert) return r.fulfill({ status: 201, headers: CORS, contentType: 'application/json', body: '[]' });
      const made = { id: `new-${calls.inserts.length}`, updated_at: now, created_at: now, feedback_history: [], ...row };
      db.articles.push(made);
      return r.fulfill({ status: 201, headers: CORS, contentType: 'application/json', body: JSON.stringify([{ id: made.id }]) });
    }
    if (req.method() === 'POST' && table === 'lce_deletion_log') {
      if (failLog) return r.fulfill({ status: 503, headers: CORS, contentType: 'application/json', body: '{"message":"log down"}' });
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

// The browser logs the injected 503s and the existence check's 400 ("already gone") as failed
// resource loads; nothing else may be logged.
const EXPECTED_HTTP = /status of (400|503)/;

module.exports = { openStudio, toast, deletesOf, deleteLibraryImage, openTrashedArticle, image, A1, A2, EXPECTED_HTTP };
