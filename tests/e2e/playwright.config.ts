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
        'comprehensive.spec.ts',
        'echo_e2e.spec.ts',
        'qa_comprehensive.spec.ts',
        'ws_check.spec.ts',
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
      ],
      use: { browserName: 'chromium' },
    },
  ],
  outputDir: './test-results',
});
