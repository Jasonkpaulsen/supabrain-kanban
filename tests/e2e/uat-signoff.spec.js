// SB-803 (FU-BTN of SB-791) — the acceptance "Sign off" button on test cases of a
// ticket in review, on all three boards (jarvis-dashboard.html, jarvis-pwa.html,
// index.html). Marker: sb803-signoff.
//
// Transport: the batch-3 write stub, plus test_cases reads and
// rpc/signoff_test_case_uat answered here. Like the rest of the stub it is NOT
// the database: the real channel check, guard (trg_uat_guard) and L4 gate
// (trg_done_gate_l4) are covered by TC-SB791-1..15 in SQL. What these cases
// prove is the client half: the button only where it belongs, exactly one RPC
// and never a PATCH, the refusal shown as the database wrote it, the stored
// state re-read, and counts_for_l4 next to the ticket level.
const { test, expect } = require('@playwright/test');
const { installWriteStubs, requestsFor, BASE } = require('./writestub');

const EMAIL = process.env.QA_FIXTURE_EMAIL;
const PASSWORD = process.env.QA_FIXTURE_PASSWORD;

test.use({ serviceWorkers: 'block' });

// ── Fixture: two L4 tickets in review, one L2 in progress ────────────────────
const proj = BASE.projects[0];
const base = BASE.items.find((i) => i.ticket_code === 'QAA-001');
const REVIEW_AT = '2026-11-06T20:00:00.000Z';
function mk(id, code, title, extra) {
  return Object.assign({}, base, {
    id, ticket_code: code, title, type: 'task', labels: [], archived: false,
    project_id: proj.id, project_name: proj.name, project_icon: proj.icon, project_domain: proj.domain,
    status: 'review', authority_level: 4, approval_status: 'approved', approved_by: 'Jason Paulsen',
    needs_jason: false, needs_jason_kind: null, waiting_days: null, aging_breached: false,
    decision_needed: null, sort_order: 60, review_entered_at: REVIEW_AT,
  }, extra);
}
const T = {
  mixed: mk('00000000-0000-4000-8000-000000000803', 'UAT-001', 'L4 review ticket with mixed cases'),
  fresh: mk('00000000-0000-4000-8000-000000000804', 'UAT-002', 'L4 review ticket not yet accepted'),
  building: mk('00000000-0000-4000-8000-000000000805', 'UAT-003', 'L2 ticket still in progress',
    { status: 'in_progress', authority_level: 2, review_entered_at: null }),
};
const SEED = Object.assign({}, BASE, { items: BASE.items.concat(Object.values(T)) });
const LIVE_TOTAL = SEED.items.filter((i) => !i.archived).length;

function tc(id, code, wi, extra) {
  return Object.assign({ id, test_code: code, title: code + ' case', work_item_id: wi, status: 'draft', archived: false,
    uat_signed_off_by: null, uat_signed_off_at: null, uat_notes: null }, extra);
}
const C = {
  active: tc('c0000000-0000-4000-8000-000000000001', 'TC-UAT-1', T.mixed.id),
  retired: tc('c0000000-0000-4000-8000-000000000002', 'TC-UAT-2', T.mixed.id, { status: 'retired' }),
  archived: tc('c0000000-0000-4000-8000-000000000003', 'TC-UAT-3', T.mixed.id, { archived: true }),
  current: tc('c0000000-0000-4000-8000-000000000004', 'TC-UAT-4', T.mixed.id,
    { uat_signed_off_by: 'Jason Paulsen', uat_signed_off_at: '2026-11-06T21:00:00.000Z', uat_notes: 'ok on phone' }),
  only: tc('c0000000-0000-4000-8000-000000000005', 'TC-UAT-5', T.fresh.id),
  wip: tc('c0000000-0000-4000-8000-000000000006', 'TC-UAT-6', T.building.id),
};

// test_cases reads and the sign-off RPC, applied to an in-memory copy.
async function installUat(page, backend) {
  const cases = JSON.parse(JSON.stringify(Object.values(C)));
  const st = backend.state;
  st.cases = cases;
  const json = (route, body, status = 200) => route.fulfill({
    status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(body) });
  await page.route('**/rest/v1/test_cases**', (route) => {
    const req = route.request();
    st.requests.push({ method: req.method(), url: req.url(), body: null });
    if (req.method() !== 'GET') return json(route, { message: 'stub: test_cases is read-only here' }, 405);
    const wi = (new URL(req.url()).searchParams.get('work_item_id') || '').replace(/^eq\./, '');
    return json(route, cases.filter((c) => c.work_item_id === wi));
  });
  await page.route('**/rest/v1/rpc/signoff_test_case_uat', (route) => {
    const req = route.request();
    const body = req.postDataJSON();
    st.requests.push({ method: 'POST', url: req.url(), body });
    if (st.refuseSignoff) return json(route, st.refuseSignoff, 400);
    if (!st.isJason) return json(route, { code: '42501', message: "GOV-001 (SB-791): signoff_test_case_uat is only for Jason's Kanban login or an attended sitting. Nothing was changed.", details: null, hint: null }, 403);
    const c = cases.find((x) => x.id === body.p_test_case_id);
    const w = st.items.find((i) => i.id === c.work_item_id);
    const at = new Date().toISOString();
    Object.assign(c, { uat_signed_off_by: 'Jason Paulsen', uat_signed_off_at: at, uat_notes: body.p_notes || null });
    return json(route, { test_code: c.test_code, ticket_code: w.ticket_code, channel: 'kanban', recorded_by: 'Jason Paulsen',
      uat_signed_off_at: at, audit_id: 'a0000000-0000-4000-8000-000000000803', counts_for_l4: true });
  });
}

function guard(page) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => { errors.push('unexpected dialog: ' + d.message()); d.dismiss(); });
  return errors;
}
function needCreds() {
  if (!EMAIL || !PASSWORD) throw new Error('QA_FIXTURE_EMAIL and QA_FIXTURE_PASSWORD must be set.');
}

async function open(page, file, isJason) {
  needCreds();
  const errors = guard(page);
  const backend = await installWriteStubs(page, SEED, { isJason });
  await installUat(page, backend);
  await page.goto('/' + file);
  if (file === 'jarvis-dashboard.html') {
    await page.fill('#login-email', EMAIL);
    await page.fill('#login-password', PASSWORD);
    await page.click('#login-btn');
    await expect(page.locator('#login-overlay')).toHaveClass(/hidden/, { timeout: 20000 });
    await page.click('.g-tab[data-tab="board"]');
    await expect(page.locator('#s-total')).toHaveText(String(LIVE_TOTAL), { timeout: 20000 });
  } else {
    await page.fill('#l-email', EMAIL);
    await page.fill('#l-pass', PASSWORD);
    await page.click('#l-btn');
    await expect(page.locator('#login-overlay')).toBeHidden({ timeout: 20000 });
    await page.waitForFunction(() => Array.isArray(window.items) && window.items.length > 25, null, { timeout: 20000 });
  }
  return { backend, errors };
}
const openTicket = (page, id) => page.evaluate((x) => openModal(x), id);
const row = (page, c) => page.locator('#m-uat .uat-case[data-case-id="' + c.id + '"]');
const signoffs = (b) => requestsFor(b, 'POST', '/rpc/signoff_test_case_uat');
const writes = (b) => b.state.requests.filter((r) => r.method !== 'GET' && !r.url.includes('/rpc/'));
const lastToast = (page) => page.locator('.toast').last();

for (const file of ['jarvis-dashboard.html', 'jarvis-pwa.html', 'index.html']) {
  test.describe(`@sb803 ${file}`, () => {
    test('TC-SB803-1 Sign off shows only on the active case; retired, archived and already-current cases have none', async ({ page }) => {
      const { errors } = await open(page, file, true);
      await openTicket(page, T.mixed.id);
      const box = page.locator('#m-uat');
      await expect(box).toBeVisible();
      await expect(box).toHaveAttribute('data-sb803', 'signoff');
      await expect(box.locator('.uat-case')).toHaveCount(4);
      await expect(row(page, C.active).locator('[data-sb803-signoff]')).toHaveCount(1);
      for (const c of [C.retired, C.archived, C.current]) {
        await expect(row(page, c).locator('[data-sb803-signoff]')).toHaveCount(0);
      }
      await expect(row(page, C.retired)).toHaveAttribute('data-state', 'retired');
      await expect(row(page, C.archived)).toHaveAttribute('data-state', 'archived');
      await expect(row(page, C.current)).toHaveAttribute('data-state', 'current');
      // counts_for_l4 next to the level: the current case already counts.
      await expect(box.locator('.uat-lvl')).toHaveText('L4');
      await expect(box.locator('.uat-l4')).toHaveAttribute('data-counts-for-l4', 'true');
      await expect(box.locator('.uat-l4')).toHaveText('counts_for_l4: yes');
      expect(errors).toEqual([]);
    });

    test('TC-SB803-2 a click with notes is one signoff_test_case_uat call, no PATCH; channel kanban and the case shows the sign-off', async ({ page }) => {
      const { backend, errors } = await open(page, file, true);
      await openTicket(page, T.fresh.id);
      const box = page.locator('#m-uat');
      await expect(box.locator('.uat-l4')).toHaveText('counts_for_l4: no');
      await row(page, C.only).locator('[data-sb803-signoff]').click();
      await row(page, C.only).locator('.uat-notes').fill('Checked on the phone');
      await row(page, C.only).locator('.uat-go').click();
      await expect(lastToast(page)).toContainText('TC-UAT-5 signed off (kanban)');
      await expect(lastToast(page)).toContainText('counts_for_l4: yes');
      expect(signoffs(backend)).toHaveLength(1);
      expect(signoffs(backend)[0].body).toEqual({ p_test_case_id: C.only.id, p_quote: null, p_notes: 'Checked on the phone' });
      expect(writes(backend)).toEqual([]);   // no PATCH of test_cases or work_items
      // Re-read from the server: the case is signed and counts.
      await expect(row(page, C.only)).toHaveAttribute('data-state', 'current');
      await expect(row(page, C.only).locator('[data-sb803-signoff]')).toHaveCount(0);
      await expect(row(page, C.only).locator('.uat-meta')).toHaveText('channel kanban · Checked on the phone');
      await expect(box.locator('.uat-l4')).toHaveAttribute('data-counts-for-l4', 'true');
      await expect(box.locator('.uat-lvl')).toHaveText('L4');
      expect(errors).toEqual([]);
    });

    test('TC-SB803-3 a click without notes sends p_notes null', async ({ page }) => {
      const { backend, errors } = await open(page, file, true);
      await openTicket(page, T.mixed.id);
      await row(page, C.active).locator('[data-sb803-signoff]').click();
      await row(page, C.active).locator('.uat-go').click();
      await expect(row(page, C.active)).toHaveAttribute('data-state', 'current');
      expect(signoffs(backend)).toHaveLength(1);
      expect(signoffs(backend)[0].body).toEqual({ p_test_case_id: C.active.id, p_quote: null, p_notes: null });
      expect(writes(backend)).toEqual([]);
      expect(errors).toEqual([]);
    });

    test('TC-SB803-4 a database refusal is shown on the case exactly as the database wrote it', async ({ page }) => {
      const { backend, errors } = await open(page, file, true);
      const msg = 'SB-791: ticket UAT-002 is L4 and in in_progress; an L4 sign-off is taken only while the ticket is in review. Nothing was changed.';
      backend.state.refuseSignoff = { code: '22023', message: msg, details: null, hint: null };
      await openTicket(page, T.fresh.id);
      await row(page, C.only).locator('[data-sb803-signoff]').click();
      await row(page, C.only).locator('.uat-go').click();
      await expect(row(page, C.only).locator('.uat-err')).toHaveText(msg);
      await expect(lastToast(page)).toHaveText(msg);
      await expect(lastToast(page)).toHaveClass(/error/);
      await expect(row(page, C.only)).toHaveAttribute('data-state', 'unsigned');
      await expect(page.locator('#m-uat .uat-l4')).toHaveText('counts_for_l4: no');
      expect(writes(backend)).toEqual([]);
      expect(errors).toEqual([]);
    });

    test('TC-SB803-5 no button outside Jason\'s login, and no section for a ticket not in review', async ({ page }) => {
      const { backend, errors } = await open(page, file, false);
      await openTicket(page, T.mixed.id);
      await expect(page.locator('#m-uat .uat-case')).toHaveCount(4);
      await expect(page.locator('#m-uat [data-sb803-signoff]')).toHaveCount(0);
      await expect(page.locator('#m-uat .uat-l4')).toHaveText('counts_for_l4: yes');
      await page.evaluate(() => closeModal());
      await openTicket(page, T.building.id);
      await expect(page.locator('#m-uat')).toBeHidden();
      expect(requestsFor(backend, 'GET', '/rest/v1/test_cases?work_item_id=eq.' + T.building.id)).toHaveLength(0);
      expect(signoffs(backend)).toHaveLength(0);
      expect(errors).toEqual([]);
    });
  });
}
