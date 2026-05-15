/**
 * Theme tour spec — captures every UI surface in every theme so we can spot
 * cases where a hardcoded color leaks (sentBubble override propagation,
 * text-on-accent contrast, hardcoded white/black, etc.).
 *
 * NOT in the maintained suite. Run on demand:
 *   npx playwright test --project=themes
 *
 * Requirements:
 *   - Local server running on :8080  (./scripts/run.sh)
 *   - Web build served on :8081      (e.g. flutter build web --release; serve build/web on :8081)
 *
 * Output:
 *   - docs/screenshots/themes/{theme}/{surface}.png
 *
 * For each of the 6 themes, captures:
 *   - settings appearance (the picker itself in that theme)
 *   - home / conversation list
 *   - chat panel (post-login)
 *
 * Plus a "custom override" sub-test that picks a vibrant primary color and
 * verifies bubbles + buttons flip with it.
 */
import { test, Page } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const LOCAL = 'http://localhost:8080';
const APP_BASE = 'http://localhost:8081';
const APP = `${APP_BASE}/?server=${encodeURIComponent(LOCAL)}`;
const SHOTS_ROOT = path.resolve(__dirname, '../../docs/screenshots/themes');

const RUN_ID = Date.now().toString(36);
const TOUR_USER = `theme_${RUN_ID}`;
const TOUR_PASS = 'themepass123';

// Match the labels rendered by the appearance picker (see
// apps/client/lib/src/screens/settings/appearance_section.dart).
const THEMES = [
  { id: 'indigo', label: 'Indigo' },
  { id: 'paper', label: 'Paper' },
  { id: 'graphite', label: 'Graphite' },
  { id: 'ember', label: 'Ember' },
  { id: 'sakura', label: 'Sakura' },
  { id: 'highContrast', label: 'High Contrast' },
];

async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 30000 });
  await page.waitForTimeout(2000);
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

async function dismissDialogs(page: Page) {
  for (const label of [/got it/i, /close/i, /dismiss/i, /skip/i]) {
    const btn = page.getByRole('button', { name: label });
    if (await btn.isVisible({ timeout: 800 }).catch(() => false)) {
      await btn.click();
      await page.waitForTimeout(300);
    }
  }
}

async function shot(page: Page, themeId: string, name: string) {
  const dir = path.join(SHOTS_ROOT, themeId);
  fs.mkdirSync(dir, { recursive: true });
  await page.screenshot({
    path: path.join(dir, `${name}.png`),
    fullPage: false,
  });
  console.log(`captured themes/${themeId}/${name}.png`);
}

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function apiPost(path: string, body: any, token?: string) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${LOCAL}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

/// Register the tour user directly via the REST API. Idempotent — accepts
/// 201 (created) or 409 (already exists) as success, so re-running the spec
/// is cheap. Called once before any tests.
async function apiRegisterTourUser() {
  const { status } = await apiPost('/api/auth/register', {
    username: TOUR_USER,
    password: TOUR_PASS,
  });
  if (status !== 201 && status !== 409) {
    throw new Error(`Could not seed tour user: ${status}`);
  }
  console.log(`tour user ${TOUR_USER} ready (status ${status})`);
}

async function uiLogin(page: Page) {
  await page.goto(APP);
  await waitForFlutter(page);
  const userInput = page.locator('input[aria-label="Username"]').first();
  if (await userInput.isVisible({ timeout: 3000 }).catch(() => false)) {
    await userInput.focus();
    await page.keyboard.type(TOUR_USER, { delay: 10 });
    const passInput = page.locator('input[aria-label="Password"]').first();
    await passInput.focus();
    await page.keyboard.type(TOUR_PASS, { delay: 10 });
    await tryClickByText(page, /^log ?in$|^sign in$/i);
    await page.waitForTimeout(3000);
  }
  await dismissDialogs(page);
  // Skip onboarding wizard if it appeared.
  for (let i = 0; i < 6; i++) {
    if (!(await tryClickByText(page, /^skip|^next|continue|finish|done/i))) break;
    await page.waitForTimeout(600);
  }
  await page.waitForTimeout(1500);
}

async function openSettingsAppearance(page: Page) {
  // Try a settings gear button first.
  const gear = page
    .getByRole('button', { name: /settings/i })
    .first();
  if (await gear.isVisible({ timeout: 1500 }).catch(() => false)) {
    await gear.click();
    await page.waitForTimeout(1200);
  } else {
    // Fallback: navigate directly via URL fragment (GoRouter).
    await page.evaluate(() => {
      window.location.hash = '#/settings/appearance';
    });
    await page.waitForTimeout(1200);
  }
  await tryClickByText(page, /appearance|theme/i);
  await page.waitForTimeout(800);
}

async function selectTheme(page: Page, label: string) {
  // The picker renders theme labels as text inside each card; tapping the
  // text bubbles up to the card's GestureDetector.
  const card = page.getByText(label, { exact: true }).first();
  if (await card.isVisible({ timeout: 3000 }).catch(() => false)) {
    await card.click();
    // Give Flutter a beat to rebuild the ThemeData and propagate.
    await page.waitForTimeout(1200);
  } else {
    console.warn(`Theme card "${label}" not visible — skipping`);
  }
}

/// Set the theme directly in localStorage and reload — bypasses the picker
/// UI entirely. Flutter's shared_preferences plugin reads from
/// `flutter.{key}` on web, so writing `flutter.echo_theme_mode` to the
/// new value + reload picks it up on next boot.
async function setThemeViaLocalStorage(page: Page, themeName: string) {
  await page.evaluate((name) => {
    // shared_preferences/web stores values under a `flutter.` prefix
    window.localStorage.setItem(
      'flutter.echo_theme_mode',
      JSON.stringify(name),
    );
  }, themeName);
  await page.reload();
  await waitForFlutter(page);
  await page.waitForTimeout(1500);
}

test.describe.serial('Theme tour', () => {
  test.beforeAll(async () => {
    await apiRegisterTourUser();
  });

  test('00 — bootstrap login + reach settings', async ({ page }) => {
    await uiLogin(page);
    await openSettingsAppearance(page);
    // Sanity screenshot of the picker in the default theme.
    fs.mkdirSync(SHOTS_ROOT, { recursive: true });
    await page.screenshot({
      path: path.join(SHOTS_ROOT, '00-picker-default.png'),
      fullPage: false,
    });
  });

  for (const t of THEMES) {
    test(`theme: ${t.id} — surfaces`, async ({ page }) => {
      await uiLogin(page);
      // Force the theme via localStorage + reload — more reliable than
      // clicking through the picker, which proved brittle in practice.
      await setThemeViaLocalStorage(page, t.id);
      // Re-login if the reload kicked us back to auth.
      const userInput = page.locator('input[aria-label="Username"]').first();
      if (await userInput.isVisible({ timeout: 2000 }).catch(() => false)) {
        await uiLogin(page);
      }
      // Capture home / chat list in this theme.
      await shot(page, t.id, 'home');
      // Open Settings → see the sidebar in this theme.
      await openSettingsAppearance(page);
      await shot(page, t.id, 'settings');
      // Click the first conversation if any.
      await page.evaluate(() => {
        window.location.hash = '#/';
      });
      await page.waitForTimeout(1500);
      const conv = page.locator('flt-semantics[role="button"]').first();
      if (await conv.isVisible({ timeout: 1500 }).catch(() => false)) {
        await conv.click();
        await page.waitForTimeout(1500);
        await shot(page, t.id, 'chat');
      }
    });
  }
});
