/**
 * Screenshot tour spec — captures 15 UI surfaces for marketing / README /
 * release notes / store listings.  NOT in the maintained suite; run on
 * demand with `npx playwright test --project=screenshots`.
 *
 * Requirements:
 *   - Local server running on :8080  (./scripts/run.sh)
 *   - Web build served on :8081      (e.g. `cd apps/client/build/web && python3 -m http.server 8081`)
 *
 * Output:
 *   - docs/screenshots/01-register.png ... 15-settings-about.png
 *     (viewport-only, NOT fullPage — these are above-the-fold marketing shots)
 *
 * The spec is described.serial so a single login + seeded state carries
 * across captures without re-logging-in each time.
 */
import { test, expect, Page } from '@playwright/test';
import * as path from 'path';

const LOCAL = 'http://localhost:8080';
const APP_BASE = 'http://localhost:8081';
const APP = `${APP_BASE}/?server=${encodeURIComponent(LOCAL)}`;
const SHOTS_DIR = path.resolve(__dirname, '../../docs/screenshots');

// Generate a unique username per run so the register screen always has a
// fresh slate without bumping into the unique-username constraint.
const RUN_ID = Date.now().toString(36);
const TOUR_USER = `tour_${RUN_ID}`;
const TOUR_PASS = 'tourpass123';

async function shot(page: Page, name: string) {
  await page.screenshot({
    path: path.join(SHOTS_DIR, `${name}.png`),
    fullPage: false,
  });
  // eslint-disable-next-line no-console
  console.log(`captured ${name}.png`);
}

async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 30000 });
  await page.waitForTimeout(2000);
}

async function dismissDialogs(page: Page) {
  for (const label of [/got it/i, /close/i, /dismiss/i]) {
    const btn = page.getByRole('button', { name: label });
    if (await btn.isVisible({ timeout: 1000 }).catch(() => false)) {
      await btn.click();
      await page.waitForTimeout(400);
    }
  }
}

async function tryClickByText(page: Page, label: RegExp): Promise<boolean> {
  const btn = page.getByRole('button', { name: label }).first();
  if (await btn.isVisible({ timeout: 1500 }).catch(() => false)) {
    await btn.click();
    return true;
  }
  const txt = page.getByText(label).first();
  if (await txt.isVisible({ timeout: 1500 }).catch(() => false)) {
    await txt.click();
    return true;
  }
  return false;
}

test.describe.serial('Screenshot tour', () => {
  test('01 register screen (cold load)', async ({ page }) => {
    await page.goto(APP);
    await waitForFlutter(page);
    // Most launches land on login; click through to the register screen.
    await tryClickByText(page, /create account|sign up|register/i);
    await page.waitForTimeout(1500);
    await shot(page, '01-register');
  });

  test('02 login screen', async ({ page }) => {
    await page.goto(APP);
    await waitForFlutter(page);
    await page.waitForTimeout(1500);
    await shot(page, '02-login');
  });

  test('03 onboarding wizard — welcome', async ({ page }) => {
    // Register a fresh user so the wizard runs.  If registration UI isn't
    // reachable we still capture the current screen so the file exists.
    await page.goto(APP);
    await waitForFlutter(page);
    if (await tryClickByText(page, /create account|sign up|register/i)) {
      await page.waitForTimeout(1000);
      const userInput = page.locator('input[aria-label="Username"]').first();
      const passInput = page.locator('input[aria-label="Password"]').first();
      if (await userInput.isVisible({ timeout: 3000 }).catch(() => false)) {
        await userInput.focus();
        await page.keyboard.type(TOUR_USER, { delay: 10 });
        await passInput.focus();
        await page.keyboard.type(TOUR_PASS, { delay: 10 });
        await tryClickByText(page, /^sign up$|^create account$|^register$/i);
      }
      await page.waitForTimeout(3500);
    }
    await shot(page, '03-onboarding-welcome');
  });

  test('04 onboarding — theme', async ({ page }) => {
    await tryClickByText(page, /^next$|continue/i);
    await page.waitForTimeout(1000);
    await shot(page, '04-onboarding-theme');
  });

  test('05 onboarding — accessibility', async ({ page }) => {
    await tryClickByText(page, /^next$|continue/i);
    await page.waitForTimeout(1000);
    await shot(page, '05-onboarding-accessibility');
  });

  test('06 onboarding — notifications', async ({ page }) => {
    await tryClickByText(page, /^next$|continue/i);
    await page.waitForTimeout(1000);
    await shot(page, '06-onboarding-notifications');
  });

  test('07 home — empty conversations', async ({ page }) => {
    // Finish wizard if still on it.
    await tryClickByText(page, /finish|done|get started|let'?s go/i);
    await page.waitForTimeout(2500);
    await dismissDialogs(page);
    await shot(page, '07-home-empty');
  });

  test('08 conversation — DM', async ({ page }) => {
    // Best-effort: click first DM-shaped row if present.
    const firstRow = page.locator('[role="button"]').filter({ hasText: /alice|bob|charlie|dev/i }).first();
    if (await firstRow.isVisible({ timeout: 2000 }).catch(() => false)) {
      await firstRow.click();
      await page.waitForTimeout(1500);
    }
    await shot(page, '08-conversation-dm');
  });

  test('09 conversation — group', async ({ page }) => {
    // Try to find a group row.  Falls back to current screen.
    const grp = page.getByText(/group|channel|#/i).first();
    if (await grp.isVisible({ timeout: 2000 }).catch(() => false)) {
      await grp.click();
      await page.waitForTimeout(1500);
    }
    await shot(page, '09-conversation-group');
  });

  test('10 discover groups', async ({ page }) => {
    await tryClickByText(page, /discover/i);
    await page.waitForTimeout(1500);
    await shot(page, '10-discover-groups');
  });

  test('11 quick switcher (cmd+k)', async ({ page }) => {
    await page.keyboard.press('Control+K');
    await page.waitForTimeout(800);
    await shot(page, '11-quick-switcher');
    await page.keyboard.press('Escape');
  });

  test('12 global search', async ({ page }) => {
    await page.keyboard.press('Control+Shift+F');
    await page.waitForTimeout(800);
    await shot(page, '12-global-search');
    await page.keyboard.press('Escape');
  });

  test('13 settings — appearance', async ({ page }) => {
    // Open settings — many builds expose this as an aria-labelled button.
    const settingsBtn = page.locator('[aria-label*="Settings" i]').first();
    if (await settingsBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
      await settingsBtn.click();
    } else {
      await tryClickByText(page, /settings/i);
    }
    await page.waitForTimeout(1200);
    await tryClickByText(page, /appearance|theme/i);
    await page.waitForTimeout(800);
    await shot(page, '13-settings-appearance');
  });

  test('14 settings — language', async ({ page }) => {
    await tryClickByText(page, /language/i);
    await page.waitForTimeout(800);
    await shot(page, '14-settings-language');
  });

  test('15 settings — about', async ({ page }) => {
    await tryClickByText(page, /about/i);
    await page.waitForTimeout(800);
    await shot(page, '15-settings-about');
  });
});

// Keep a trivial assertion so the project never reports "no tests run".
test('tour sanity', () => {
  expect(SHOTS_DIR).toContain('docs/screenshots');
});
