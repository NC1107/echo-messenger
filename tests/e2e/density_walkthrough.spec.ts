/**
 * Manual smoke test for the Phase 2 density tiers shipped in PR #817.
 *
 * Walks Settings → Appearance → Density and screenshots the three tiers
 * (Cozy / Normal / Compact) on the surfaces that picked up density in
 * this PR: sidebar, message stream, channel bar, settings rows, voice
 * dock, reactions, date divider.
 *
 * Run against production once the main-branch release deploy lands:
 *
 *   ECHO_SERVER=https://echo-messenger.us \
 *   ECHO_URL=https://echo-messenger.us \
 *   npx playwright test density_walkthrough.spec.ts \
 *     --project=manual --headed --timeout=300000
 *
 * Or against a local dev stack (default):
 *
 *   npx playwright test density_walkthrough.spec.ts --project=manual --headed
 */
import { test, Page, expect } from '@playwright/test';

const SERVER = process.env.ECHO_SERVER || 'http://localhost:8080';
const WEB = process.env.ECHO_URL || 'http://localhost:8081';
const APP = `${WEB}/?server=${encodeURIComponent(SERVER)}`;
const SS = 'tests/e2e/test-results/density';

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function waitForFlutter(page: Page) {
  await page.waitForFunction(
    () =>
      document.querySelector('flt-semantics') !== null ||
      document.querySelector('input[aria-label]') !== null,
    { timeout: 30000 },
  );
  await page.waitForTimeout(2000);
}

async function loginAsNew(page: Page, username: string, password: string) {
  // Register via REST first; falls back to login if the username already
  // exists (e.g. the spec is rerun without rotating the suffix).
  const reg = await fetch(`${SERVER}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  })
    .then((r) => r.json())
    .catch(() => ({}));
  // Some servers rate-limit registration; if so, sign in via the existing
  // account flow.  The test only needs a logged-in session.
  if (!reg.access_token) {
    await fetch(`${SERVER}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
  }

  await page.goto(APP);
  await waitForFlutter(page);
  await page.getByLabel('Username').click();
  await page.waitForTimeout(200);
  await page.keyboard.type(username, { delay: 10 });
  // Tab to the password field — getByLabel('Password') is ambiguous in
  // CanvasKit because the show/hide eye-icon also carries an aria-label
  // hit by the same heuristic.
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 10 });
  await page.getByRole('button', { name: /^log in$/i }).click();
  await page.waitForTimeout(8000);
}

async function openSettings(page: Page) {
  // Settings is reachable from the user-status footer in the left sidebar.
  // Try by aria label first; fall back to a common gear icon click.
  const settingsBtn = page.getByRole('button', { name: /settings/i }).first();
  if (await settingsBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await settingsBtn.click();
  } else {
    // Hash route fallback — the GoRouter route map exposes /settings.
    await page.goto(`${APP}#/settings`);
  }
  await page.waitForTimeout(1500);
}

async function selectDensity(page: Page, label: 'Cozy' | 'Normal' | 'Compact') {
  // Density radio is in the Appearance section, directly below the
  // Message Layout picker.  Each tile renders with semantics label
  // "<Label> layout" — Cozy/Normal are unique, Compact appears twice
  // (once for message layout, once for density), so for Compact we
  // pick the second match (density tile lives after the layout tiles).
  const appearance = page
    .getByRole('button', { name: /appearance settings/i })
    .first();
  if (await appearance.isVisible({ timeout: 2000 }).catch(() => false)) {
    await appearance.click();
    await page.waitForTimeout(800);
  }
  const tiles = page.getByRole('button', {
    name: new RegExp(`^${label} layout$`, 'i'),
  });
  const idx = label === 'Compact' ? 1 : 0;
  await tiles.nth(idx).click({ timeout: 5000 });
  await page.waitForTimeout(800);
}

test('density tier visual walkthrough', async ({ browser }) => {
    test.setTimeout(0);
    const ts = Date.now().toString().slice(-5);
    const u = `density_${ts}`;
    const pw = 'densitypass123';

    const ctx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const page = await ctx.newPage();

    await loginAsNew(page, u, pw);
    await ss(page, '00-loaded');

    // 1. Default density (today's compact) — sidebar reference.
    await ss(page, '01-default-sidebar');

    // 2. Open settings, snap each density tier.
    await openSettings(page);
    await ss(page, '02-settings-default');

    for (const tier of ['Cozy', 'Normal', 'Compact'] as const) {
      await selectDensity(page, tier);
      await ss(page, `03-settings-${tier.toLowerCase()}`);

      // Pop back to home so we capture the sidebar at this density.
      const backBtn = page.getByRole('button', { name: /^back$/i }).first();
      if (await backBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
        await backBtn.click();
        await page.waitForTimeout(800);
      } else {
        await page.goto(APP);
        await page.waitForTimeout(2000);
      }
      await ss(page, `04-home-${tier.toLowerCase()}`);

      // Re-enter settings for the next iteration.
      await openSettings(page);
    }

  // No assertions — this is a screenshot-collection smoke for visual review.
  expect(true).toBe(true);
  await ctx.close();
});
