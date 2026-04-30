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
      // Smoke: one comprehensive end-to-end flow that exercises the full
      // feature surface.  Run on every CI push via --project=smoke.
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
      ],
      use: { browserName: 'chromium' },
    },
  ],
  outputDir: './test-results',
});
