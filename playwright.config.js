// Playwright config for the JARVIS Kanban Board Tab QA suite (SB-100).
// Batches are tagged so each SB-339/340/341 batch can be run on its own:
//   npx playwright test --grep @batch1
const { defineConfig, devices } = require('@playwright/test');

const PORT = process.env.QA_PORT || 8099;

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
      // Use the browser already on the runner rather than downloading one.
      launchOptions: process.env.QA_CHROMIUM_PATH
        ? { executablePath: process.env.QA_CHROMIUM_PATH }
        : {},
    },
  }],
  webServer: {
    command: `python3 -m http.server ${PORT} --bind 127.0.0.1`,
    url: `http://127.0.0.1:${PORT}/jarvis-dashboard.html`,
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
  },
});
