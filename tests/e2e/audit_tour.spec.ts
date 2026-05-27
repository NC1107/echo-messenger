/**
 * Theme audit tour — registry-driven.
 *
 * Iterates `audit_surfaces.ts` × every variant × every beta theme and writes
 * PNGs to `screenshot_audit/{theme}/{area}/{filename}.png`. The surface
 * registry is the single source of truth — adding or removing a surface is
 * one edit there, not here.
 *
 * Run on demand:
 *   cd tests/e2e && npx playwright test --project=audit
 *
 * Target a different server:
 *   AUDIT_SERVER=https://us-east.echo-messenger.us \
 *   AUDIT_APP=https://web.echo-messenger.us \
 *     npx playwright test --project=audit
 *
 * Defaults to local: server :8080 + web build :8081.
 *
 * Each run creates a fresh user (timestamped username) and seeds a
 * predictable peer + DM + group so the captures stay consistent across
 * runs and across servers.
 */
import { test, Page } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';
import {
  SURFACES,
  Surface,
  Viewport,
  Density,
  MessageLayout,
  generateAreasMarkdown,
} from './audit_surfaces';

const SERVER = process.env.AUDIT_SERVER ?? 'http://localhost:8080';
const APP_BASE = process.env.AUDIT_APP ?? 'http://localhost:8081';
const APP = APP_BASE.includes('://localhost')
  ? `${APP_BASE}/?server=${encodeURIComponent(SERVER)}`
  : APP_BASE; // prod web build reads its server from config, not query
const SHOTS_ROOT = path.resolve(__dirname, '../../screenshot_audit');

const RUN_ID = Date.now().toString(36);
const TOUR_USER = `audit_${RUN_ID}`;
const TOUR_PASS = 'auditpass123';
const PEER_USER = `audit_peer_${RUN_ID}`;
const PEER_PASS = 'auditpass123';

const THEMES: Array<{ id: 'indigo' | 'paper' | 'ember' }> = [
  { id: 'indigo' },
  { id: 'paper' },
  { id: 'ember' },
];

const DESKTOP = { width: 1920, height: 1080 } as const;
const MOBILE = { width: 420, height: 900 } as const;

// ---------------------------------------------------------------------------
// Browser primitives
// ---------------------------------------------------------------------------

async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 30000 });
  await page.waitForTimeout(2000);
}

async function shot(theme: string, area: string, fileName: string, page: Page) {
  const dir = path.join(SHOTS_ROOT, theme, area);
  fs.mkdirSync(dir, { recursive: true });
  await page.screenshot({
    path: path.join(dir, `${fileName}.png`),
    fullPage: false,
  });
  console.log(`captured ${theme}/${area}/${fileName}.png`);
}

async function tryClickByText(
  page: Page,
  label: RegExp,
  timeoutMs = 1500,
): Promise<boolean> {
  // Per-click timeout (5 s) — without it, the click inherits the test
  // budget (900 s) and a single stuck click (overlay, animation, etc.)
  // wedges the whole theme. The audit prefers skipping a surface over
  // hanging — failures land as console warnings in the safe() wrapper.
  const clickTimeoutMs = 5000;
  const btn = page.getByRole('button', { name: label }).first();
  if (await btn.isVisible({ timeout: timeoutMs }).catch(() => false)) {
    try {
      await btn.click({ timeout: clickTimeoutMs });
      return true;
    } catch (_) {
      // fall through to text-locator path
    }
  }
  const txt = page.getByText(label).first();
  if (await txt.isVisible({ timeout: timeoutMs }).catch(() => false)) {
    try {
      await txt.click({ timeout: clickTimeoutMs });
      return true;
    } catch (_) {
      return false;
    }
  }
  return false;
}

async function gotoHash(page: Page, hash: string) {
  await page.evaluate((h) => {
    window.location.hash = h;
  }, hash);
  await page.waitForTimeout(1000);
}

// ---------------------------------------------------------------------------
// Persisted-pref helpers — write directly to localStorage and reload so the
// app boots with the requested setting without clicking through pickers.
// ---------------------------------------------------------------------------

async function setPref(page: Page, key: string, value: string) {
  await page.evaluate(
    ([k, v]) => {
      window.localStorage.setItem(`flutter.${k}`, JSON.stringify(v));
    },
    [key, value],
  );
}

async function applyPrefs(
  page: Page,
  prefs: Record<string, string>,
  needsReload = true,
) {
  for (const [k, v] of Object.entries(prefs)) {
    await setPref(page, k, v);
  }
  if (needsReload) {
    await page.reload();
    await waitForFlutter(page);
    await page.waitForTimeout(1200);
    // Re-login if reload bounced us to auth.
    const userInput = page.locator('input[aria-label="Username"]').first();
    if (await userInput.isVisible({ timeout: 2000 }).catch(() => false)) {
      await uiLogin(page);
    }
  }
}

// ---------------------------------------------------------------------------
// API seeding
// ---------------------------------------------------------------------------

async function apiPost(p: string, body: any, token?: string) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${SERVER}${p}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function registerUser(username: string, password: string) {
  const reg = await apiPost('/api/auth/register', { username, password });
  if (reg.status === 201) return reg.data.access_token as string;
  // Fallback: login.
  const login = await apiPost('/api/auth/login', { username, password });
  return login.data.access_token as string;
}

async function seedConversations(token: string) {
  await registerUser(PEER_USER, PEER_PASS);
  await apiPost('/api/contacts/add', { username: PEER_USER }, token);
  for (const text of [
    'hey there 👋',
    'how is the audit going?',
    'looks good — heading to lunch',
    'back, picking up where we left off',
  ]) {
    await apiPost(
      '/api/messages/send',
      { recipient: PEER_USER, content: text, content_type: 'text' },
      token,
    );
  }
  await apiPost(
    '/api/groups/create',
    { name: 'Audit Group', members: [PEER_USER] },
    token,
  );
}

// ---------------------------------------------------------------------------
// UI flows
// ---------------------------------------------------------------------------

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
    await page.waitForTimeout(2500);
  }
  // Auto-skip onboarding if it appeared — capture is handled by the
  // dedicated onboarding test instead.
  for (let i = 0; i < 6; i++) {
    if (!(await tryClickByText(page, /^skip|^next|continue|finish|done/i))) break;
    await page.waitForTimeout(500);
  }
  await page.waitForTimeout(1200);
}

// ---------------------------------------------------------------------------
// Spec
// ---------------------------------------------------------------------------

test.describe.serial('Audit tour', () => {
  test.setTimeout(900_000); // 15-min budget per test.

  test.beforeAll(async () => {
    const token = await registerUser(TOUR_USER, TOUR_PASS);
    await seedConversations(token);
    console.log(`Seeded ${TOUR_USER} + ${PEER_USER}; target ${SERVER}`);
  });

  // --- AUTH + ONBOARDING — captured pre-login, once, copied across themes ---
  test('00 — auth + onboarding (theme-neutral)', async ({ page }) => {
    const dir = path.join(SHOTS_ROOT, 'indigo', 'auth');
    fs.mkdirSync(dir, { recursive: true });

    await page.goto(APP);
    await waitForFlutter(page);

    // Splash — brief, but try to catch it before the login form settles.
    try {
      await page.screenshot({ path: path.join(dir, 'splash.png') });
    } catch {}

    await page.waitForTimeout(1500);
    await page.screenshot({ path: path.join(dir, 'login.png') });

    // Server picker (if reachable from login).
    if (await tryClickByText(page, /change server|server settings/i, 1500)) {
      await page.waitForTimeout(600);
      await page.screenshot({ path: path.join(dir, 'server-picker.png') });
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
    }

    // Register.
    if (await tryClickByText(page, /sign up|create an account|register/i, 1500)) {
      await page.waitForTimeout(800);
      await page.screenshot({ path: path.join(dir, 'register.png') });
    }

    // Forgot.
    await tryClickByText(page, /already have an account|back to log/i, 1500);
    await page.waitForTimeout(500);
    if (await tryClickByText(page, /forgot/i, 1500)) {
      await page.waitForTimeout(800);
      await page.screenshot({ path: path.join(dir, 'forgot-password.png') });
    }

    // Register a brand-new user and capture the onboarding wizard step-by-step.
    await page.goto(APP);
    await waitForFlutter(page);
    const onboardUser = `onboard_${RUN_ID}`;
    await tryClickByText(page, /sign up|create an account|register/i, 1500);
    await page.waitForTimeout(500);
    const userInput = page.locator('input[aria-label="Username"]').first();
    if (await userInput.isVisible({ timeout: 2500 }).catch(() => false)) {
      await userInput.focus();
      await page.keyboard.type(onboardUser, { delay: 8 });
      const passInput = page.locator('input[aria-label="Password"]').first();
      await passInput.focus();
      await page.keyboard.type(TOUR_PASS, { delay: 8 });
      const confirm = page
        .locator('input[aria-label*="confirm" i]')
        .first();
      if (await confirm.isVisible({ timeout: 800 }).catch(() => false)) {
        await confirm.focus();
        await page.keyboard.type(TOUR_PASS, { delay: 8 });
      }
      await tryClickByText(page, /sign up|register|create account/i, 1500);
      await page.waitForTimeout(2500);
    }

    // Walk the wizard, screenshotting each step.
    const wizardSteps = [
      'onboarding-welcome',
      'onboarding-presets',
      'onboarding-final',
    ];
    for (const name of wizardSteps) {
      await page.screenshot({ path: path.join(dir, `${name}.png`) });
      if (!(await tryClickByText(page, /next|continue|finish|done|get started/i, 1500))) {
        break;
      }
      await page.waitForTimeout(800);
    }
    await tryClickByText(page, /skip|done|finish/i, 1500);
    await page.waitForTimeout(600);

    // Copy auth + onboarding shots into paper/ + ember/ (the auth screens
    // are loaded BEFORE the theme provider hydrates from localStorage, so
    // they always render in the default — copying makes the audit tree
    // complete without three full re-runs of the login flow).
    for (const t of ['paper', 'ember'] as const) {
      const peer = path.join(SHOTS_ROOT, t, 'auth');
      fs.mkdirSync(peer, { recursive: true });
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith('.png')) fs.copyFileSync(path.join(dir, f), path.join(peer, f));
      }
    }
  });

  // --- One test per theme — iterates the registry × variants ---
  for (const t of THEMES) {
    test(`theme: ${t.id} — surfaces`, async ({ page }) => {
      await uiLogin(page);
      await applyPrefs(page, { echo_theme_mode: t.id });

      const reachCtx = {
        peerUser: PEER_USER,
        click: (label: RegExp, timeoutMs?: number) =>
          tryClickByText(page, label, timeoutMs),
        goto: (hash: string) => gotoHash(page, hash),
      };

      for (const surface of SURFACES.filter((s) => !s.skip && s.requires !== 'fresh')) {
        await captureSurface(page, surface, t.id, reachCtx);
      }
    });
  }

  // --- Generated AREAS.md keeps the docs in sync ---
  test('99 — regenerate AREAS.md from registry', async () => {
    const out = path.resolve(SHOTS_ROOT, 'AREAS.md');
    fs.writeFileSync(out, generateAreasMarkdown(), 'utf8');
    console.log(`wrote ${out}`);
  });
});

// ---------------------------------------------------------------------------
// Per-surface capture — handles every variant. Failures are caught and
// logged but never rethrown, so one bad reach doesn't break the tour.
// ---------------------------------------------------------------------------

async function captureSurface(
  page: Page,
  surface: Surface,
  theme: string,
  ctx: any,
) {
  const viewports: Viewport[] = ['desktop'];
  if (surface.variants?.mobile) viewports.push('mobile');

  const densities: (Density | null)[] = surface.variants?.densities
    ? surface.variants.densities
    : [null];

  const layouts: (MessageLayout | null)[] = surface.variants?.messageLayouts
    ? surface.variants.messageLayouts
    : [null];

  for (const viewport of viewports) {
    await page.setViewportSize(viewport === 'mobile' ? MOBILE : DESKTOP);
    await page.waitForTimeout(400);

    for (const density of densities) {
      if (density) {
        await applyPrefs(page, {
          echo_theme_mode: theme,
          echo_ui_density: density,
        });
      }
      for (const layout of layouts) {
        if (layout) {
          await applyPrefs(page, {
            echo_theme_mode: theme,
            echo_message_layout: layout,
          });
        }
        try {
          await surface.reach(page, ctx);
          const fileName = composeFilename(surface.id, viewport, density, layout);
          await shot(theme, surface.area, fileName, page);
          // Best-effort cleanup so the next surface starts from a clean slate.
          await page.keyboard.press('Escape').catch(() => {});
          await page.waitForTimeout(200);
        } catch (e) {
          console.warn(
            `⚠ ${theme}/${surface.area}/${surface.id} (${viewport}/${density ?? '-'}/${layout ?? '-'}) failed: ${e}`,
          );
        }
      }
    }
  }

  // Restore desktop for the next surface.
  await page.setViewportSize(DESKTOP);
  await page.waitForTimeout(200);
}

/// `dm.png` → `dm.png`
/// `dm.png` + mobile → `dm-mobile.png`
/// `conv-list-populated` + mobile + density=cozy → `conv-list-populated-mobile-cozy.png`
function composeFilename(
  id: string,
  viewport: Viewport,
  density: Density | null,
  layout: MessageLayout | null,
): string {
  const parts: string[] = [id];
  if (viewport === 'mobile') parts.push('mobile');
  if (density) parts.push(density);
  if (layout) parts.push(`layout-${layout}`);
  return parts.join('-');
}
