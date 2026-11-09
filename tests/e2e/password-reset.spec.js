// Password recovery (marker: sb-password-reset): "Forgot password?" on the sign-in
// forms, the reset-password.html landing page, and the way back to the Codex approval.
//
// Render-level only. Auth is stubbed here, so no email is sent and no password is
// changed: these cases prove the client half (what is asked of /auth/v1 and what the
// user sees), not Supabase's redirect allow-list or its email delivery. They need no
// fixture credentials.
const { test, expect } = require('@playwright/test');

const SUPABASE_UMD = require.resolve('@supabase/supabase-js/dist/umd/supabase.js');
const USER = {
  id: '00000000-0000-4000-8000-00000000a001', aud: 'authenticated', role: 'authenticated',
  email: 'qa-user@example.test', app_metadata: { provider: 'email' }, user_metadata: {},
  created_at: '2026-11-01T00:00:00Z',
};
const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(body),
});
const RECOVERY_HASH = '#access_token=qa-recovery-token&expires_in=3600&expires_at=' +
  (Math.floor(Date.now() / 1000) + 3600) + '&refresh_token=qa-refresh&token_type=bearer&type=recovery';
const EXPIRED_HASH = '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired';

async function stub(page) {
  const calls = [];
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => { errors.push('unexpected dialog: ' + d.message()); d.dismiss(); });
  await page.route('**/cdn.jsdelivr.net/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', path: SUPABASE_UMD }));
  await page.route('**/auth/v1/**', (route) => {
    const req = route.request();
    calls.push({ method: req.method(), url: req.url(), body: req.postData() });
    if (req.url().includes('/recover')) return json(route, {});
    if (req.url().includes('/user')) return json(route, USER);
    return json(route, {});
  });
  await page.route('**/rest/v1/**', (route) => json(route, []));
  return { calls, errors };
}

test('@pwreset TC-PWR-1 index.html: Forgot password asks for the email, then sends a reset to reset-password.html', async ({ page, baseURL }) => {
  const { calls, errors } = await stub(page);
  await page.goto('/index.html');
  const forgot = page.locator('#pr-forgot');
  await expect(forgot).toBeVisible();
  await forgot.click();
  await expect(page.locator('#pr-msg')).toContainText('Enter your email address above');
  expect(calls.filter((c) => c.url.includes('/recover'))).toHaveLength(0);

  await page.fill('#l-email', 'qa-user@example.test');
  await forgot.click();
  await expect(page.locator('#pr-msg')).toContainText('The link works once and expires in about an hour');
  const rec = calls.filter((c) => c.url.includes('/recover'));
  expect(rec).toHaveLength(1);
  expect(new URL(rec[0].url).searchParams.get('redirect_to')).toBe(baseURL + '/reset-password.html');
  expect(JSON.parse(rec[0].body).email).toBe('qa-user@example.test');
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-2 jarvis-pwa.html and jarvis-dashboard.html offer Forgot password', async ({ page }) => {
  const { errors } = await stub(page);
  for (const file of ['jarvis-pwa.html', 'jarvis-dashboard.html']) {
    await page.goto('/' + file);
    await expect(page.locator('#pr-forgot'), file).toBeVisible();
  }
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-3 an expired link shows a clear message and a send-a-new-link form', async ({ page }) => {
  const { calls, errors } = await stub(page);
  await page.goto('/reset-password.html' + EXPIRED_HASH);
  await expect(page.locator('#request-title')).toHaveText('This link has expired');
  await expect(page.locator('#request-why')).toContainText('expired or was already used');
  await expect(page.locator('#set')).toBeHidden();
  await page.fill('#r-email', 'qa-user@example.test');
  await page.click('#r-btn');
  await expect(page.locator('#r-msg')).toContainText('Check your email');
  expect(calls.filter((c) => c.url.includes('/recover'))).toHaveLength(1);
  expect(page.url()).not.toContain('error_description');
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-4 a recovery link that lands on index.html is forwarded to reset-password.html', async ({ page }) => {
  const { errors } = await stub(page);
  await page.goto('/index.html' + RECOVERY_HASH);
  await page.waitForURL(/\/reset-password\.html/);
  await expect(page.locator('#set')).toBeVisible();
  await expect(page.locator('#who')).toHaveText('qa-user@example.test');
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-5 set a new password: validation, updateUser, no Codex link without a stored return', async ({ page }) => {
  const { calls, errors } = await stub(page);
  await page.goto('/reset-password.html' + RECOVERY_HASH);
  await expect(page.locator('#set')).toBeVisible();
  await page.fill('#p1', 'short'); await page.fill('#p2', 'short');
  await page.click('#set-btn');
  await expect(page.locator('#set-err')).toHaveText('Use at least 8 characters.');
  await page.fill('#p1', 'a-long-password-1'); await page.fill('#p2', 'a-long-password-2');
  await page.click('#set-btn');
  await expect(page.locator('#set-err')).toHaveText('The two passwords do not match.');
  expect(calls.filter((c) => c.method === 'PUT')).toHaveLength(0);

  await page.fill('#p2', 'a-long-password-1');
  await page.click('#set-btn');
  await expect(page.locator('#done')).toBeVisible();
  const put = calls.filter((c) => c.method === 'PUT' && c.url.includes('/user'));
  expect(put).toHaveLength(1);
  expect(JSON.parse(put[0].body).password).toBe('a-long-password-1');
  await expect(page.locator('#back-consent')).toBeHidden();
  expect(page.url()).not.toContain('access_token');
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-6 from the Codex approval page, the reset ends with a link back to that authorization', async ({ page, baseURL }) => {
  const { errors } = await stub(page);
  await page.goto('/oauth-consent.html?authorization_id=qa-auth-1');
  await expect(page.locator('#login')).toBeVisible();
  await page.fill('#l-email', 'qa-user@example.test');
  await page.click('#pr-forgot');
  await expect(page.locator('#pr-msg')).toContainText('Check your email');

  // The email link opens a new tab: sessionStorage starts empty there, localStorage does not.
  const tab = await page.context().newPage();
  await stub(tab);
  await tab.goto('/reset-password.html' + RECOVERY_HASH);
  await tab.fill('#p1', 'a-long-password-1'); await tab.fill('#p2', 'a-long-password-1');
  await tab.click('#set-btn');
  const back = tab.locator('#back-consent');
  await expect(back).toBeVisible();
  expect(await back.getAttribute('href')).toBe(baseURL + '/oauth-consent.html?authorization_id=qa-auth-1');
  expect(errors).toEqual([]);
});

test('@pwreset TC-PWR-7 opened with no link and no session, the page offers to send one', async ({ page }) => {
  const { errors } = await stub(page);
  await page.goto('/reset-password.html');
  await expect(page.locator('#request-title')).toHaveText('Send a reset link');
  await expect(page.locator('#set')).toBeHidden();
  expect(errors).toEqual([]);
});
