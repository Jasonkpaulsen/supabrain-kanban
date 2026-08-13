// Playwright config for the JARVIS Kanban Board Tab QA suite (SB-100).
// Batches are tagged so each SB-339/340/341 batch can be run on its own:
//   npx playwright test --grep @batch1
const { defineConfig, devices } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const PORT = process.env.QA_PORT || 8099;

// Runners here ship a pre-provisioned Chromium under PLAYWRIGHT_BROWSERS_PATH,
// but its build number tracks the image rather than the pinned @playwright/test
// version — so the revision Playwright looks for by default may not be the one
// on disk, and downloads are blocked. Resolve whatever build is actually
// present instead of relying on an env var being exported in the caller's
// shell, which is easy to lose between sessions.
function findChromium() {
  if (process.env.QA_CHROMIUM_PATH) return process.env.QA_CHROMIUM_PATH;
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!root || !fs.existsSync(root)) return undefined;
  const build = fs.readdirSync(root)
    .filter((d) => /^chromium-\d+$/.test(d))
    .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]))[0];
  if (!build) return undefined;
  const bin = path.join(root, build, 'chrome-linux', 'chrome');
  return fs.existsSync(bin) ? bin : undefined;
}

const CHROMIUM = findChromium();

module.exports = defineConfig({
  testDir: './tests/e2e',
  // The board reads from the live Supabase project, so tests share a fixture
  // dataset and must not race each other.
  workers: 1,
  fullyParallel: false,
  timeout: 45000,
  expect: { timeout: 10000 },
  reporter: [['list'], ['json', { outputFile: 'test-results/results.json' }]],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 1600, height: 1000 },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [{
    name: 'chromium',
    use: {
      ...devices['Desktop Chrome'],
      // Full Chromium, not the headless shell: the shell is a separate download
      // that this image does not always carry, and headless: true would pick it.
      channel: undefined,
      launchOptions: CHROMIUM ? { executablePath: CHROMIUM } : {},
    },
  }],
  webServer: {
    command: `python3 -m http.server ${PORT} --bind 127.0.0.1`,
    url: `http://127.0.0.1:${PORT}/jarvis-dashboard.html`,
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
  },
});
