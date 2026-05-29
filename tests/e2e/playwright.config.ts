import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  timeout: 120000,
  use: {
    baseURL: 'http://localhost:8081',
    screenshot: 'on',
    trace: 'on',
    video: 'retain-on-failure',
  },
  projects: [
    {
      // Smoke: full end-to-end flow gating every CI push.  continue-on-error
      // until #673 (CanvasKit selector brittleness) fully settles.
      name: 'smoke',
      testMatch: ['local_full.spec.ts'],
      use: { browserName: 'chromium' },
    },
    {
      // Maintained: targeted UI and protocol specs that give per-feature
      // regression signal on every PR/push.  Run via --project=maintained.
      name: 'maintained',
      testMatch: [
        'semantics_e2e.spec.ts',
        'group_create_ui.spec.ts',
        'group_messaging_ui.spec.ts',
        'hover_then_type.spec.ts',
        'crypto_dm_test.spec.ts',
        'group_encryption_roundtrip.spec.ts',
        'comprehensive.spec.ts',
        'echo_e2e.spec.ts',
        'qa_comprehensive.spec.ts',
        'ws_check.spec.ts',
        'voice_lounge_canvas_sync.spec.ts',
        'voice_lounge_mobile_audit.spec.ts',
      ],
      use: { browserName: 'chromium' },
    },
    {
      // Manual: prod/live specs that target a running production instance.
      // Never run in CI -- require ECHO_SERVER + ECHO_URL env vars pointing
      // at a live deployment.  Listed here so the spec-coverage validator
      // doesn't reject them.
      name: 'manual',
      testMatch: [
        'live_full.spec.ts',
        'live_test.spec.ts',
        'open_prod.spec.ts',
        'prod_test.spec.ts',
        'density_walkthrough.spec.ts',
      ],
      use: { browserName: 'chromium' },
    },
    {
      // Screenshots: one-shot tour for marketing / README / release notes.
      // Run on demand:  npx playwright test --project=screenshots
      // Requires a local server on :8080 + web build on :8081.  Output PNGs
      // land in docs/screenshots/.
      name: 'screenshots',
      testMatch: ['screenshot_tour.spec.ts'],
      use: {
        browserName: 'chromium',
        viewport: { width: 1920, height: 1080 },
      },
    },
    {
      // Theme tour: switches through every theme and captures key surfaces
      // so hardcoded-color leaks become visible. Run on demand:
      //   npx playwright test --project=themes
      // Output: docs/screenshots/themes/{theme}/{surface}.png
      name: 'themes',
      testMatch: ['theme_tour.spec.ts'],
      use: {
        browserName: 'chromium',
        viewport: { width: 1920, height: 1080 },
      },
    },
    {
      // Audit tour: full surface sweep × 3 beta themes for the screenshot
      // audit. Run on demand:
      //   npx playwright test --project=audit
      // Output: screenshot_audit/{theme}/{area}/{screen}.png
      name: 'audit',
      testMatch: ['audit_tour.spec.ts'],
      use: {
        browserName: 'chromium',
        viewport: { width: 1920, height: 1080 },
      },
    },
  ],
  outputDir: './test-results',
});
