// SB-623 (TC-SB623-04): the per-project automation toggle reads and writes
// projects.automation_status, which is what agent-runner gates on (SB-390).
//
// Before SB-623 the toggle read and wrote meta.dev_automation, a key nothing reads any
// more, so the board could show "on" for a project the runner skipped (and the
// reverse). The fixture sets the two disagreeing on purpose: Alpha is paused with a
// stale meta.dev_automation='on', Beta is active with no meta.dev_automation (it
// carries only a dead dev_automation_config, for TC-SB625-03). A board that
// still reads meta gets both wrong.
//
// Enabling now really starts agents, so it asks first; pausing does not. A failed RPC
// leaves the toggle where it was. Stubbed backend, as in cards.spec.js; each test routes
// rpc/set_project_dev_automation itself because the stub refuses writes.
const { test, expect } = require('@playwright/test');
const { login, loginPwa } = require('./fixture');
const BASE = require('./fixtures/cards-payload.json');

const ALPHA = '774e3715-a787-471d-b8d3-c82f97b751a2';
const BETA = '07701eb0-4362-4469-acbb-5bbf01034bd3';

function buildPayload() {
  const p = JSON.parse(JSON.stringify(BASE));
  for (const proj of p.projects) {
    if (proj.id === ALPHA) { proj.automation_status = 'paused'; proj.meta = { ...proj.meta, dev_automation: 'on' }; }
    // SB-625: Beta carries a per-project WIP config that nothing applies; the dashboard
    // must not present it as a cap.
    else { proj.automation_status = 'active'; proj.meta = { ...proj.meta, dev_automation_config: { wip_limit_per_run: 3 } }; }
  }
  return p;
}
const PAYLOAD = buildPayload();
// The dashboard's total leaves out cancelled rows.
const DASH_TOTAL = PAYLOAD.items.filter((i) => i.status !== 'cancelled').length;

// Route the RPC; `reply(body)` decides the response. Returns the list of request bodies.
async function routeRpc(page, reply) {
  const calls = [];
  await page.route('**/rest/v1/rpc/set_project_dev_automation', (route) => {
    const body = JSON.parse(route.request().postData() || '{}');
    calls.push(body);
    const out = reply(body);
    return route.fulfill({ status: out.status || 200, contentType: 'application/json', body: JSON.stringify(out.body) });
  });
  return calls;
}
const ok = (name) => (b) => ({ body: { ok: true, project: name, automation_status: b.p_on ? 'active' : 'paused', dev_automation: b.p_on ? 'on' : 'off' } });

const SURFACES = [
  { name: 'dashboard', doc: '/jarvis-dashboard.html', tgl: '#proj-auto-tgl', wrap: '#proj-auto-wrap',
    open: (page) => login(page, { payload: PAYLOAD, expectTotal: DASH_TOTAL }) },
  { name: 'pwa', doc: '/jarvis-pwa.html', tgl: '#pa-tgl', wrap: '#pa-wrap',
    open: (page) => loginPwa(page, { payload: PAYLOAD }) },
  { name: 'index', doc: '/index.html', tgl: '#pa-tgl', wrap: '#pa-wrap',
    open: (page) => loginPwa(page, { payload: PAYLOAD, doc: '/index.html' }) },
];

async function pick(page, id) {
  const pill = page.locator(`.proj-pill[data-id="${id}"]`);
  await pill.click();
  await expect(pill).toHaveClass(/active/);
}
async function expectState(page, s, on) {
  const b = page.locator(s.tgl);
  await expect(b).toHaveAttribute('data-on', on ? '1' : '0');
  await expect(b).toHaveText(on ? 'on' : 'off');
}

for (const s of SURFACES) {
  test.describe(`@sb623 ${s.name}`, () => {
    test(`TC-SB623-04a ${s.name}: toggle shows automation_status, not meta.dev_automation`, async ({ page }) => {
      const errs = await s.open(page);
      await expect(page.locator(s.wrap)).toBeHidden();
      await pick(page, ALPHA);
      await expect(page.locator(s.wrap)).toBeVisible();
      await expectState(page, s, false);
      await pick(page, BETA);
      await expectState(page, s, true);
      expect(errs).toEqual([]);
    });

    test(`TC-SB625-03 ${s.name}: no per-project WIP hint, even when meta carries a config`, async ({ page }) => {
      const errs = await s.open(page);
      await pick(page, BETA);
      await expectState(page, s, true);
      await expect(page.locator('#proj-auto-hint')).toHaveCount(0);
      await expect(page.locator(s.wrap)).not.toContainText(/WIP/i);
      expect(errs).toEqual([]);
    });

    test(`TC-SB623-04b ${s.name}: enabling asks first; dismiss sends nothing, accept writes active`, async ({ page }) => {
      const errs = await s.open(page);
      const calls = await routeRpc(page, ok('QA Fixture Alpha'));
      await pick(page, ALPHA);

      const dialogs = [];
      page.once('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
      await page.locator(s.tgl).click();
      await expect.poll(() => dialogs.length).toBe(1);
      expect(dialogs[0]).toMatch(/agents will start/i);
      await page.waitForTimeout(200);
      expect(calls).toEqual([]);
      await expectState(page, s, false);

      page.once('dialog', (d) => d.accept());
      await page.locator(s.tgl).click();
      await expect.poll(() => calls.length).toBe(1);
      expect(calls[0]).toEqual({ p_project_id: ALPHA, p_on: true });
      await expectState(page, s, true);
      await expect(page.locator('.toast').last()).toHaveText('QA Fixture Alpha: automation active');
      // The new state sticks across a project switch (it lives on the project row).
      await pick(page, BETA); await pick(page, ALPHA);
      await expectState(page, s, true);
      expect(errs).toEqual([]);
    });

    test(`TC-SB623-04c ${s.name}: pausing needs no confirm and writes paused`, async ({ page }) => {
      const errs = await s.open(page);
      const calls = await routeRpc(page, ok('QA Fixture Beta'));
      const dialogs = [];
      page.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
      await pick(page, BETA);
      await page.locator(s.tgl).click();
      await expect.poll(() => calls.length).toBe(1);
      expect(calls[0]).toEqual({ p_project_id: BETA, p_on: false });
      await expectState(page, s, false);
      await expect(page.locator('.toast').last()).toHaveText('QA Fixture Beta: automation paused');
      expect(dialogs).toEqual([]);
      expect(errs).toEqual([]);
    });

    test(`TC-SB623-04d ${s.name}: a refused or failed RPC leaves the toggle as it was`, async ({ page }) => {
      const errs = await s.open(page);
      let n = 0;
      const calls = await routeRpc(page, () => (++n === 1
        ? { body: { ok: false, error: 'project not found or not yours' } }
        : { status: 500, body: { message: 'boom' } }));
      await pick(page, BETA);
      for (let i = 1; i <= 2; i++) {
        await page.locator(s.tgl).click();
        await expect.poll(() => calls.length).toBe(i);
        await expect(page.locator('.toast.error').last()).toHaveText('Automation update failed');
        await expectState(page, s, true);
        await expect(page.locator(s.tgl)).toBeEnabled();
      }
      // The 500 is logged by the browser as a failed resource load; nothing else may be.
      expect(errs.filter((e) => !/status of 500/.test(e))).toEqual([]);
    });
  });
}
