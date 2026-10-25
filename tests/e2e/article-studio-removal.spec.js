// SB-631 (TC-SB631-01..05): Article Studio removes an image row only when its file went.
//
// deleteStorage used to check r.ok alone. The Storage API answers 200 with an empty list when
// nothing matched, so a removal that removed nothing looked done, and destroy, emptyTrash and
// deleteImage then removed the image_assets rows anyway, leaving the files in project-assets
// with nothing pointing at them (and, after SB-627, no way for the user to remove them).
//
// Stubbed backend, as in cards.spec.js: auth and the vendored supabase-js come from stub.js's
// conventions; REST and Storage are a small stateful stub (article-studio-stub.js). Each test sets what the
// Storage DELETE reports as removed, then asserts the writes the page sent.
const { test, expect } = require('@playwright/test');
const { openStudio, toast, deletesOf, deleteLibraryImage, openTrashedArticle, image, A1, A2 } = require('./article-studio-stub');

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
    const { calls, errors } = await openStudio(page);
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
    // SB-635: the image row that did go is logged; the kept article is not
    expect(calls.logs).toEqual([expect.objectContaining({ entity_type: 'image', entity_id: 'i1', reason: 'manual_delete' })]);
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
    expect(calls.logs).toEqual([
      expect.objectContaining({ entity_type: 'image', entity_id: 'i1', reason: 'manual_empty_trash' }),
      expect.objectContaining({ entity_type: 'image', entity_id: 'i3', reason: 'manual_empty_trash' }),
      expect.objectContaining({ entity_type: 'article', entity_id: A2, reason: 'manual_empty_trash' }),
    ]);
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

  // The browser logs the injected 503s and the existence check's 400 ("already gone") as failed
  // resource loads; nothing else may be logged.
  const EXPECTED_HTTP = /status of (400|503)/;

  // Verifier, 2026-10-24: an empty removal answer also means "already gone". Without the HEAD
  // check, a row whose file went but whose row delete failed could never be removed.
  test('TC-SB631-06a library image: a retry after a failed row delete removes the row', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page, { failImageDeletes: 1 });
    await deleteLibraryImage(page, 'img lib1');
    await expect(toast(page)).toHaveText(/^Image not removed: /);
    expect(db.files.has('lce-images/library/saved-1.png')).toBe(false);
    expect(calls.logs).toEqual([]);
    await page.locator('#libGrid .card', { hasText: 'img lib1' }).locator('button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.heads).toContain('lce-images/library/saved-1.png');
    expect(deletesOf(calls, 'image_assets').filter((d) => !d.failed)).toEqual([{ table: 'image_assets', ids: ['lib1'] }]);
    expect(calls.logs).toEqual([expect.objectContaining({ entity_id: 'lib1', reason: 'manual_delete' })]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB631-06b article in Trash: a retry after a failed row delete removes the article', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page, { failImageDeletes: 1 });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText(/^Images not removed: /);
    expect(deletesOf(calls, 'articles')).toEqual([]);
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(deletesOf(calls, 'image_assets').filter((d) => !d.failed)).toEqual([{ table: 'image_assets', ids: ['i1', 'i2'] }]);
    expect(deletesOf(calls, 'articles')).toEqual([{ table: 'articles', ids: [A1] }]);
    expect(db.articles.map((a) => a.id)).not.toContain(A1);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB631-06c two rows on one path: removing the second after the first still works', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page);
    await deleteLibraryImage(page, 'img dupA');
    await expect(toast(page)).toHaveText('Deleted');
    await expect(page.locator('#libGrid .card', { hasText: 'img dupA' })).toHaveCount(0);
    await page.locator('#libGrid .card', { hasText: 'img dupB' }).locator('button:has-text("Delete")').click();
    // the toast still says Deleted from the first removal, so wait on the card instead
    await expect(page.locator('#libGrid .card', { hasText: 'img dupB' })).toHaveCount(0);
    // SB-633: the first removal leaves the file (dupB still uses it); the second takes it
    expect(calls.storage).toEqual([['lce-images/library/dup.png']]);
    expect(db.files.has('lce-images/library/dup.png')).toBe(false);
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['dupA'] }, { table: 'image_assets', ids: ['dupB'] }]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB631-07 a failed image lookup stops the removal', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { failImageGet: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('lookup down');
    expect(calls.storage).toEqual([]);
    expect(calls.deletes).toEqual([]);
    expect(calls.logs).toEqual([]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  // Re-verify, 2026-10-24: only 400/404 mean gone. A 500 or a failed HEAD is unknown and keeps the
  // row; a path with a space, + or ? must be encoded or the check would look at the wrong object.
  test('TC-SB631-08a an unknown existence answer keeps the row', async ({ page }) => {
    for (const head of [500, 'abort']) {
      const ctx = await page.context().browser().newContext({ serviceWorkers: 'block' });
      const p = await ctx.newPage();
      const { calls, db } = await openStudio(p, { removes: () => false, head });
      db.files.delete('lce-images/library/saved-1.png');
      await deleteLibraryImage(p, 'img lib1');
      await expect(toast(p)).toHaveText('File not removed — image kept');
      expect(calls.heads).toEqual(['lce-images/library/saved-1.png']);
      expect(calls.deletes).toEqual([]);
      await ctx.close();
    }
  });

  test('TC-SB631-08b the existence check encodes the path', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page, { removes: () => false });
    db.files.delete('lce-images/library/with space+plus?.png');
    await deleteLibraryImage(page, 'img spaced');
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.heads).toEqual(['lce-images/library/with space+plus?.png']);
    expect(deletesOf(calls, 'image_assets')).toEqual([{ table: 'image_assets', ids: ['spaced'] }]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  // SB-633: saved and library images are not part of an article's removal.
  test('TC-SB633-02a deleting an article leaves its saved image alone', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.storage.flat()).not.toContain(`lce-images/${A1}/saved.png`);
    expect(deletesOf(calls, 'image_assets').flatMap((d) => d.ids)).not.toContain('sv');
    expect(deletesOf(calls, 'articles')).toEqual([{ table: 'articles', ids: [A1] }]);
    expect(db.images.map((i) => i.id)).toContain('sv');
    expect(db.files.has(`lce-images/${A1}/saved.png`)).toBe(true);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB633-02b Empty Trash leaves saved and library images alone', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page);
    await page.locator("[onclick=\"setFilter('trashed')\"]").first().click();
    await page.locator('button:has-text("Empty Trash")').click();
    await expect(toast(page)).toHaveText('Purged 2');
    expect(calls.storage.flat().filter((p) => /saved\.png|library\.png/.test(p))).toEqual([]);
    expect(deletesOf(calls, 'image_assets').flatMap((d) => d.ids).sort()).toEqual(['i1', 'i2', 'i3']);
    expect(db.images.map((i) => i.id)).toEqual(expect.arrayContaining(['sv', 'lb']));
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  // SB-635: manual removals log their image rows, and a failed log write is reported.
  test('TC-SB635-04a deleting an article logs its image rows and the article', async ({ page }) => {
    const { calls, errors } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.logs.map((l) => `${l.entity_type}:${l.entity_id}:${l.reason}`).sort()).toEqual(
      [`article:${A1}:manual_delete`, 'image:i1:manual_delete', 'image:i2:manual_delete']);
    expect(calls.logs.find((l) => l.entity_id === 'i1').storage_path).toBe(`lce-images/${A1}/candidate-1.png`);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB635-04b a failed purge-log write is reported, not hidden', async ({ page }) => {
    const { calls } = await openStudio(page, { failLog: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted — purge log not written');
    expect(deletesOf(calls, 'articles')).toEqual([{ table: 'articles', ids: [A1] }]);
  });

  // Verifier, 2026-10-25: a file shared with a surviving row stays.
  test('TC-SB633-02c a file shared with a library image is not removed with the article', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page);
    db.images.push(image('libdup', `lce-images/${A1}/candidate-1.png`, null, 'saved'));
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.storage.flat()).not.toContain(`lce-images/${A1}/candidate-1.png`);
    expect(db.files.has(`lce-images/${A1}/candidate-1.png`)).toBe(true);
    expect(deletesOf(calls, 'image_assets').flatMap((d) => d.ids).sort()).toEqual(['i1', 'i2']);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB633-02d deleting an article leaves its library image alone', async ({ page }) => {
    const { calls, errors, db } = await openStudio(page);
    await openTrashedArticle(page, 'Trashed two');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Deleted');
    expect(calls.storage.flat()).not.toContain(`lce-images/${A2}/library.png`);
    expect(deletesOf(calls, 'image_assets').flatMap((d) => d.ids)).toEqual(['i3']);
    expect(db.images.map((i) => i.id)).toContain('lb');
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });

  test('TC-SB635-04c a library delete with a failed purge log says so', async ({ page }) => {
    await openStudio(page, { failLog: true }).then(() => deleteLibraryImage(page, 'img lib1'));
    await expect(toast(page)).toHaveText('Deleted — purge log not written');
  });

  test('TC-SB635-04d image rows removed before a failed article delete are still logged', async ({ page }) => {
    const { calls } = await openStudio(page, { failArticleDelete: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('article delete down');
    expect(calls.logs.map((l) => `${l.entity_type}:${l.entity_id}`).sort()).toEqual(['image:i1', 'image:i2']);
  });

  test('TC-SB633-02e a failed shared-file lookup removes nothing', async ({ page }) => {
    const { calls, errors } = await openStudio(page, { failSharedLookup: true });
    await openTrashedArticle(page, 'Trashed one');
    await page.locator('#sheetActions button:has-text("Delete")').click();
    await expect(toast(page)).toHaveText('Images not removed: shared lookup down');
    expect(calls.storage).toEqual([]);
    expect(calls.deletes).toEqual([]);
    expect(calls.logs).toEqual([]);
    expect(errors.filter((e) => !EXPECTED_HTTP.test(e))).toEqual([]);
  });
});
