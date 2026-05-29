/**
 * Playwright config for the deep mobile-canvas audit.
 *
 * Distinct from the main `playwright.config.ts` because the audit:
 *  - records video for every spec (not just on failure),
 *  - keeps tracing on for every spec,
 *  - has its own output dir so the per-state screenshots land alongside
 *    the markdown report rather than in `test-results/`.
 *
 * Run via `scripts/audit_lounge_deep.sh`.
 */
import { defineConfig } from '@playwright/test';
import * as path from 'node:path';

const OUT = path.resolve(__dirname, 'output');

export default defineConfig({
  testDir: '.',
  // The audit drives a sequence of tools × devices × orientations and
  // intentionally runs ~5-10 minutes per device. The default 30s timeout
  // would kill it before the first device finished.
  timeout: 15 * 60 * 1000,
  expect: { timeout: 10_000 },
  retries: 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: path.join(OUT, 'html-report') }]],
  use: {
    baseURL: process.env.ECHO_URL || 'http://localhost:8081',
    screenshot: 'on',
    trace: 'on',
    video: 'on',
    // 30s per individual action is fine; bumped because mobile emulation +
    // CanvasKit boot can chew 5-15s.
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
  },
  projects: [
    {
      name: 'deep-audit',
      testMatch: ['voice_lounge_mobile_audit.spec.ts'],
      use: { browserName: 'chromium' },
    },
  ],
  outputDir: path.join(OUT, 'pw-output'),
});
