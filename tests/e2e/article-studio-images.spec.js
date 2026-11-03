// LCE-021: Article Studio mobile image curation (candidates, accept/save/reject, request a new set,
// Image Library, use a saved image). Runs the real page at 390x844 on a touch device against an
// in-memory Supabase stub that applies the same PostgREST/RPC calls the page makes and records them.
//
// WHAT THIS CANNOT DO: it is not Postgres. set_article_header is emulated here from its definition
// (copy for saved/library images per SB-643, move for candidates). The database half is checked
// separately with SQL against the live project.
const { test, expect } = require('@playwright/test');

const SUPABASE_UMD = require.resolve('@supabase/supabase-js/dist/umd/supabase.js');
const { SESSION } = require('./stub');

const A1 = '11111111-1111-4111-8111-111111111111';
const A2 = '22222222-2222-4222-8222-222222222222';
const img = (id, status, article_id, extra = {}) => ({
  id, status, article_id, user_id: SESSION.user.id, storage_bucket: 'project-assets',
  storage_path: `lce-images/${id}.png`, public_url: `https://example.test/${id}.png`,
  description: `image ${id}`, sort_order: 0, meta: {}, updated_at: '2026-11-03T12:00:00Z', ...extra,
});

function seed() {
  return {
    articles: [
      { id: A1, title: 'Forty Things Nobody Wanted', hook: 'Production was never the bottleneck.', status: 'draft', pillar: 'Personal Build Stories', updated_at: '2026-11-03T12:00:00Z', image_asset_id: null, feedback_history: [] },
      { id: A2, title: 'Context Is the New Integration Project', hook: 'Nobody budgeted for it.', status: 'draft', pillar: 'AI in Enterprise', updated_at: '2026-11-02T12:00:00Z', image_asset_id: null, feedback_history: [] },
    ],
    image_assets: [
      img('c1', 'candidate', A1, { sort_order: 1 }),
      img('c2', 'candidate', A1, { sort_order: 2 }),
      img('c3', 'candidate', A1, { sort_order: 3 }),
      img('l1', 'library', null),
      img('l2', 'library', null),
      img('s1', 'saved', A2),
    ],
    image_requests: [],
  };
}

async function install(page, opts = {}) {
  const state = seed();
  const requests = [];
  let n = 0;
  const json = (route, body, status = 200) => route.fulfill({
    status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(body),
  });
  const filters = (url) => {
    const out = [];
    for (const [k, v] of new URL(url).searchParams) {
      if (['select', 'order', 'limit', 'offset'].includes(k)) continue;
      if (v.startsWith('eq.')) out.push((r) => String(r[k]) === v.slice(3));
      else if (v.startsWith('in.(')) { const set = v.slice(4, -1).split(','); out.push((r) => set.includes(String(r[k]))); }
      else if (v === 'is.null') out.push((r) => r[k] == null);
    }
    return (r) => out.every((f) => f(r));
  };
  const order = (url, rows) => {
    const o = new URL(url).searchParams.get('order');
    if (!o) return rows;
    const [col, dir] = o.split('.');
    return rows.slice().sort((a, b) => (a[col] > b[col] ? 1 : a[col] < b[col] ? -1 : 0) * (dir === 'desc' ? -1 : 1));
  };

  // SB-643 / SB-636: the same contract as public.set_article_header.
  function setArticleHeader({ p_article_id, p_image_id }) {
    const art = state.articles.find((a) => a.id === p_article_id);
    const src = state.image_assets.find((i) => i.id === p_image_id);
    if (!art) throw new Error('set_article_header: article not found');
    if (!src) throw new Error('set_article_header: image not found');
    const lib = ['saved', 'library'].includes(src.status);
    state.image_assets.filter((i) => i.article_id === p_article_id && i.status === 'accepted' && i.id !== p_image_id)
      .forEach((i) => { i.status = i.meta && i.meta.copied_from ? 'rejected' : 'saved'; });
    let target = p_image_id;
    if (lib) {
      target = `copy-${++n}`;
      state.image_assets.push({ ...src, id: target, article_id: p_article_id, status: 'accepted', meta: { ...(src.meta || {}), copied_from: src.id } });
    } else {
      state.articles.filter((a) => a.image_asset_id === p_image_id && a.id !== p_article_id).forEach((a) => { a.image_asset_id = null; });
      src.status = 'accepted'; src.article_id = p_article_id;
    }
    art.image_asset_id = target;
    return { ok: true, image_id: target };
  }

  await page.route('**/cdn.jsdelivr.net/**', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD }));
  await page.route('**/auth/v1/**', (route) => {
    const url = route.request().url();
    if (url.includes('/token')) return json(route, SESSION);
    if (url.includes('/user')) return json(route, SESSION.user);
    return json(route, {});
  });
  await page.route('**/rest/v1/**', async (route) => {
    const req = route.request();
    const url = req.url();
    const method = req.method();
    let body = null;
    try { body = req.postDataJSON(); } catch { /* none */ }
    requests.push({ method, url, body });
    const table = new URL(url).pathname.split('/rest/v1/')[1];

    if (table === 'rpc/set_article_header') {
      if (opts.failRpc) return json(route, { message: 'set_article_header: article not updated', code: '42501' }, 400);
      try { return json(route, setArticleHeader(body)); } catch (e) { return json(route, { message: e.message }, 400); }
    }
    const rows = state[table];
    if (!rows) return json(route, []);
    if (method === 'GET') {
      let out = order(url, rows.filter(filters(url)));
      const lim = new URL(url).searchParams.get('limit');
      if (lim) out = out.slice(0, Number(lim));
      return json(route, out);
    }
    if (method === 'PATCH') {
      if (table === 'image_assets' && opts.rlsHideImages) return json(route, []); // RLS: matched nothing, no error
      const hit = rows.filter(filters(url));
      hit.forEach((r) => Object.assign(r, body));
      return json(route, hit.map((r) => ({ id: r.id })));
    }
    if (method === 'POST') {
      const list = Array.isArray(body) ? body : [body];
      const made = list.map((b) => ({ id: `req-${++n}`, created_at: new Date(Date.now() + n).toISOString(), status: 'pending', ...b }));
      rows.push(...made);
      return json(route, made, 201);
    }
    return json(route, []);
  });
  return { state, requests, calls: (m, frag) => requests.filter((r) => r.method === m && r.url.includes(frag)) };
}

async function signIn(page) {
  await page.goto('/article-studio/index.html');
  await page.fill('#email', 'qa-fixture@supabrain.test');
  await page.fill('#password', 'x');
  await page.click('text=Enter Studio');
  await expect(page.locator('#list .card').first()).toBeVisible();
}
async function openArticle(page, title) {
  await page.locator('#list .card', { hasText: title }).click();
  await expect(page.locator('#sheet.open')).toBeVisible();
  await expect(page.locator('#imgZone .lbl')).toBeVisible();
  await expect(page.locator('#imgZone')).not.toContainText('Loading');
}
const toast = (page) => page.locator('#toast');
const noHorizontalScroll = async (page) =>
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);

test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });

test.describe('LCE-021 Article Studio image curation @lce021', () => {
  test('TC-LCE021-V1 candidates show as a swipeable gallery of near full-width cards', async ({ page }) => {
    await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    const gal = page.locator('#imgZone .gallery').first();
    await expect(gal.locator('.imgcard')).toHaveCount(3);
    const m = await gal.evaluate((el) => {
      const cs = getComputedStyle(el);
      return { snap: cs.scrollSnapType, overflow: cs.overflowX, scrollW: el.scrollWidth, clientW: el.clientWidth, cardW: el.firstElementChild.getBoundingClientRect().width };
    });
    expect(m.snap).toContain('x');
    expect(m.overflow).toBe('auto');
    expect(m.scrollW).toBeGreaterThan(m.clientW);
    expect(m.cardW).toBeGreaterThanOrEqual(m.clientW - 30);
    await expect(page.locator('#imgZone .galpos i')).toHaveCount(3);
    await expect(page.locator('#imgZone .galpos i').nth(0)).toHaveClass(/on/);
    await gal.evaluate((el) => { el.scrollLeft = el.firstElementChild.offsetWidth + 10; el.dispatchEvent(new Event('scroll')); });
    await expect(page.locator('#imgZone .galpos i').nth(1)).toHaveClass(/on/);
    await noHorizontalScroll(page);
  });

  test('TC-LCE021-V2 every image control is at least 44px tall', async ({ page }) => {
    await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    const heights = await page.locator('#imgZone button').evaluateAll((bs) => bs.map((b) => [b.textContent.trim(), b.getBoundingClientRect().height]));
    expect(heights.length).toBeGreaterThanOrEqual(11); // 3 cards x 3 actions + Request set + Use saved
    for (const [label, h] of heights) expect(h, label).toBeGreaterThanOrEqual(44);
  });

  test('TC-LCE021-V3 Accept sets the header through set_article_header in one call', async ({ page }) => {
    const be = await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#imgZone .gallery .imgcard').nth(1).locator('button', { hasText: 'Accept' }).tap();
    await expect(toast(page)).toHaveText('Set as header');
    const rpc = be.calls('POST', '/rpc/set_article_header');
    expect(rpc).toHaveLength(1);
    expect(rpc[0].body).toEqual({ p_article_id: A1, p_image_id: 'c2' });
    expect(be.calls('PATCH', '/rest/v1/articles')).toHaveLength(0);
    expect(be.state.articles.find((a) => a.id === A1).image_asset_id).toBe('c2');
    await expect(page.locator('#imgZone .hero img')).toHaveAttribute('src', /c2\.png/);
    await expect(page.locator('#imgZone .gallery .imgcard')).toHaveCount(2);
  });

  test('TC-LCE021-V4 a failed Accept says so and leaves the header unset', async ({ page }) => {
    const be = await install(page, { failRpc: true });
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#imgZone .gallery .imgcard').first().locator('button', { hasText: 'Accept' }).tap();
    await expect(toast(page)).toContainText('Header not changed');
    expect(be.state.articles.find((a) => a.id === A1).image_asset_id).toBeNull();
    await expect(page.locator('#imgZone .hero')).toHaveCount(0);
  });

  test('TC-LCE021-V5 Save and Reject write the status and confirm the row changed', async ({ page }) => {
    const be = await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#imgZone .gallery .imgcard').first().locator('button', { hasText: 'Save' }).tap();
    await expect(toast(page)).toHaveText('Saved to library');
    await expect(page.locator('#imgZone .gallery .imgcard')).toHaveCount(2);
    await page.locator('#imgZone .gallery .imgcard').first().locator('button', { hasText: 'Reject' }).tap();
    await expect(toast(page)).toHaveText('Rejected');
    await expect(page.locator('#imgZone .gallery .imgcard')).toHaveCount(1);
    const patches = be.calls('PATCH', '/rest/v1/image_assets');
    expect(patches.map((p) => p.body)).toEqual([{ status: 'saved' }, { status: 'rejected' }]);
    patches.forEach((p) => expect(p.url).toContain('select=id'));
    expect(be.state.image_assets.find((i) => i.id === 'c1').status).toBe('saved');
    expect(be.state.image_assets.find((i) => i.id === 'c2').status).toBe('rejected');
  });

  test('TC-LCE021-V6 a Save that RLS ignores reports Not saved and keeps the card', async ({ page }) => {
    await install(page, { rlsHideImages: true });
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#imgZone .gallery .imgcard').first().locator('button', { hasText: 'Save' }).tap();
    await expect(toast(page)).toContainText('Not saved');
    await expect(page.locator('#imgZone .gallery .imgcard')).toHaveCount(3);
  });

  test('TC-LCE021-V7 Request set shows a waiting state, then the new set when it lands', async ({ page }) => {
    await page.clock.install();
    const be = await install(page);
    await signIn(page);
    await openArticle(page, 'Context Is the New');
    await page.fill('#imgfb', 'brighter, no text');
    await page.locator('#reqBtn').tap();
    await expect(toast(page)).toHaveText('New set requested');
    const posts = be.calls('POST', '/rest/v1/image_requests');
    expect(posts).toHaveLength(1);
    expect(posts[0].body).toMatchObject({ article_id: A2, feedback: 'brighter, no text', count: 3, status: 'pending' });
    await expect(page.locator('#imgReq')).toContainText('next image run');
    await expect(page.locator('#reqBtn')).toBeDisabled();
    // The worker delivers: request done, three candidates on the article.
    be.state.image_requests[0].status = 'done';
    ['n1', 'n2', 'n3'].forEach((id, k) => be.state.image_assets.push(img(id, 'candidate', A2, { sort_order: k })));
    await page.clock.fastForward(61000);
    await expect(toast(page)).toHaveText('New images ready');
    await expect(page.locator('#imgZone .gallery .imgcard')).toHaveCount(3);
    await expect(page.locator('#imgReq')).toHaveCount(0);
    await expect(page.locator('#reqBtn')).toBeEnabled();
  });

  test('TC-LCE021-V8 a failed request is shown with its error', async ({ page }) => {
    const be = await install(page);
    be.state.image_requests.push({ id: 'rf', article_id: A2, status: 'failed', error: 'Gemini 402: credits depleted', created_at: '2026-11-03T10:00:00Z' });
    await signIn(page);
    await openArticle(page, 'Context Is the New');
    await expect(page.locator('#imgReq.err')).toContainText('credits depleted');
    await expect(page.locator('#reqBtn')).toBeEnabled();
  });

  test('TC-LCE021-V9 Use saved lists saved and library images and copies the chosen one', async ({ page }) => {
    const be = await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#imgZone button', { hasText: 'Use saved' }).tap();
    const cards = page.locator('#libPick .gallery .imgcard');
    await expect(cards).toHaveCount(3); // l1, l2 (status library) + s1 (status saved)
    const use = cards.first().locator('button', { hasText: 'Use this image' });
    expect((await use.boundingBox()).height).toBeGreaterThanOrEqual(44);
    const firstId = await cards.first().locator('img').getAttribute('src');
    await use.tap();
    await expect(toast(page)).toHaveText('Set as header');
    const rpc = be.calls('POST', '/rpc/set_article_header');
    expect(rpc).toHaveLength(1);
    const srcId = rpc[0].body.p_image_id;
    expect(firstId).toContain(srcId);
    // Copy, not move: the library row is untouched and still reusable.
    const src = be.state.image_assets.find((i) => i.id === srcId);
    expect(['saved', 'library']).toContain(src.status);
    const header = be.state.image_assets.find((i) => i.id === be.state.articles.find((a) => a.id === A1).image_asset_id);
    expect(header.meta.copied_from).toBe(srcId);
    await expect(page.locator('#libPick')).toBeEmpty();
    await expect(page.locator('#imgZone .hero')).toBeVisible();
    await noHorizontalScroll(page);
  });

  test('TC-LCE021-V10 Library tab opens onto saved and library images with reachable Delete', async ({ page }) => {
    await install(page);
    await signIn(page);
    await page.locator('#n-lib').tap();
    await expect(page.locator('#libGrid .card')).toHaveCount(3);
    await expect(page.locator('#stats')).toBeHidden();
    await expect(page.locator('#recs')).toBeHidden();
    const del = page.locator('#libGrid .card').first().locator('button', { hasText: 'Delete' });
    const box = await del.boundingBox();
    const navTop = (await page.locator('nav.bottom').boundingBox()).y;
    expect(box.height).toBeGreaterThanOrEqual(44);
    expect(box.y + box.height).toBeLessThanOrEqual(navTop);
    await noHorizontalScroll(page);
    await page.locator('#n-board').tap();
    await expect(page.locator('#stats')).toBeVisible();
    await expect(page.locator('#recs')).toBeVisible();
  });

  test('TC-LCE021-V11 a late image load does not draw into a closed or different article', async ({ page }) => {
    const be = await install(page);
    await signIn(page);
    await openArticle(page, 'Forty Things');
    await page.locator('#sheet .shead button').tap();
    await openArticle(page, 'Context Is the New');
    // A load that was started for A1 finishes now, after A2 is open.
    await page.evaluate((id) => loadArticleImages(id), A1);
    // None of A1's candidates (c1..c3) may appear in A2's sheet, in any markup.
    await expect(page.locator('#imgZone img[src*="/c1.png"], #imgZone img[src*="/c2.png"], #imgZone img[src*="/c3.png"]')).toHaveCount(0);
    await expect(page.locator('#imgZone')).toContainText('No images yet');
    expect(be.calls('GET', `article_id=eq.${A1}`).length).toBeGreaterThan(0);
  });
});
