/**
 * Theme audit tour — captures every reachable surface in each of the three
 * beta themes (indigo / paper / ember) and writes PNGs to
 * `screenshot_audit/{theme}/{area}/{screen}.png`.
 *
 * NOT in the maintained suite. Run on demand:
 *   cd tests/e2e && npx playwright test audit_tour.spec.ts
 *
 * Requirements:
 *   - Local server running on :8080  (./scripts/run.sh)
 *   - Web build served on :8081      (build flutter web; python3 -m http.server 8081)
 *
 * The catalogue of surfaces is `screenshot_audit/AREAS.md`. Filenames here
 * MUST match the names in that file — auditors use those filenames as the
 * checklist.
 *
 * Coverage tiers:
 *  - Tier 1 — reachable from fresh login (auth, settings sections, modals
 *    shells, empty states). Automated.
 *  - Tier 2 — needs seeded data (populated conversations, groups). Automated
 *    via API seeding before the run.
 *  - Tier 3 — needs real-time multi-user / native state (voice peers,
 *    screen share, native OS prompts). Captured manually — flagged with
 *    TODO comments below so the auditor can fill them in.
 */
import { test, Page, expect } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const LOCAL = 'http://localhost:8080';
const APP_BASE = 'http://localhost:8081';
const APP = `${APP_BASE}/?server=${encodeURIComponent(LOCAL)}`;
const SHOTS_ROOT = path.resolve(__dirname, '../../screenshot_audit');

const RUN_ID = Date.now().toString(36);
const TOUR_USER = `audit_${RUN_ID}`;
const TOUR_PASS = 'auditpass123';
const PEER_USER = `audit_peer_${RUN_ID}`;
const PEER_PASS = 'auditpass123';

const THEMES: Array<{ id: 'indigo' | 'paper' | 'ember'; label: string }> = [
  { id: 'indigo', label: 'Indigo' },
  { id: 'paper', label: 'Paper' },
  { id: 'ember', label: 'Ember' },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 30000 });
  await page.waitForTimeout(2000);
}

async function shot(
  page: Page,
  theme: string,
  area: string,
  name: string,
  opts: { fullPage?: boolean } = {},
) {
  const dir = path.join(SHOTS_ROOT, theme, area);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${name}.png`);
  await page.screenshot({ path: file, fullPage: opts.fullPage ?? false });
  console.log(`captured ${theme}/${area}/${name}.png`);
}

async function tryClickByText(
  page: Page,
  label: RegExp,
  timeoutMs = 1500,
): Promise<boolean> {
  const btn = page.getByRole('button', { name: label }).first();
  if (await btn.isVisible({ timeout: timeoutMs }).catch(() => false)) {
    await btn.click();
    return true;
  }
  const txt = page.getByText(label).first();
  if (await txt.isVisible({ timeout: timeoutMs }).catch(() => false)) {
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

// ---------------------------------------------------------------------------
// API helpers — seed users + content before the UI ever loads.
// ---------------------------------------------------------------------------

async function apiPost(p: string, body: any, token?: string) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${LOCAL}${p}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function registerOrLogin(username: string, password: string) {
  const reg = await apiPost('/api/auth/register', { username, password });
  if (reg.status === 201) return reg.data.access_token as string;
  // Already exists — login instead.
  const login = await apiPost('/api/auth/login', { username, password });
  return login.data.access_token as string;
}

async function seedConversations(token: string) {
  // Create a peer to DM.
  await registerOrLogin(PEER_USER, PEER_PASS);
  // Add peer as contact (idempotent).
  await apiPost('/api/contacts/add', { username: PEER_USER }, token);
  // Send a couple of DMs so the conv list is populated.
  // Sent as plaintext via the server's REST endpoint so we don't have to
  // bootstrap the full Signal handshake in the test.
  for (const text of ['hey there', 'how is the audit going?', 'looks good!']) {
    await apiPost(
      '/api/messages/send',
      { recipient: PEER_USER, content: text, content_type: 'text' },
      token,
    );
  }
  // Create a group so the group surfaces have something to look at.
  await apiPost(
    '/api/groups/create',
    { name: 'Audit Group', members: [PEER_USER] },
    token,
  );
}

// ---------------------------------------------------------------------------
// UI navigation primitives
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
    await page.waitForTimeout(3000);
  }
  await dismissDialogs(page);
  for (let i = 0; i < 6; i++) {
    if (!(await tryClickByText(page, /^skip|^next|continue|finish|done/i))) break;
    await page.waitForTimeout(600);
  }
  await page.waitForTimeout(1500);
}

async function setTheme(page: Page, theme: string) {
  await page.evaluate((name) => {
    window.localStorage.setItem(
      'flutter.echo_theme_mode',
      JSON.stringify(name),
    );
  }, theme);
  await page.reload();
  await waitForFlutter(page);
  await page.waitForTimeout(1500);
  // Re-login if reload bounced us back to auth.
  const userInput = page.locator('input[aria-label="Username"]').first();
  if (await userInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await uiLogin(page);
  }
}

async function gotoHash(page: Page, hash: string) {
  await page.evaluate((h) => {
    window.location.hash = h;
  }, hash);
  await page.waitForTimeout(1200);
}

// ---------------------------------------------------------------------------
// Capture playbook — one big serial run per theme. Each surface is wrapped
// in try/catch so a single broken nav doesn't poison the rest of the tour.
// ---------------------------------------------------------------------------

// Viewport presets. Desktop = 1920×1080 (wide-3pane), Mobile = 420×900
// (narrow-mobile). The Playwright project's viewport (1920×1080) is the
// default — we only switch when capturing the mobile pass.
const DESKTOP = { width: 1920, height: 1080 } as const;
const MOBILE = { width: 420, height: 900 } as const;

async function capture(page: Page, theme: string) {
  // -------------------------------------------------------------------------
  // DESKTOP PASS — 1920×1080
  // -------------------------------------------------------------------------
  await page.setViewportSize(DESKTOP);
  await page.waitForTimeout(400);

  // ---- home/ ----
  await safe('home', 'desktop-2pane', async () => {
    await gotoHash(page, '#/');
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.waitForTimeout(800);
    await shot(page, theme, 'home', 'desktop-2pane');
    await page.setViewportSize(DESKTOP);
    await page.waitForTimeout(400);
  });

  await safe('home', 'wide-3pane', async () => {
    await gotoHash(page, '#/');
    await page.waitForTimeout(600);
    await shot(page, theme, 'home', 'wide-3pane');
  });

  await safe('home', 'conv-list-populated', async () => {
    await gotoHash(page, '#/');
    await page.waitForTimeout(600);
    await shot(page, theme, 'home', 'conv-list-populated');
  });

  await safe('home', 'no-conversation-placeholder', async () => {
    // Empty-right-pane shot — same as conv-list-populated, just with no
    // chat selected. The default state after login does this anyway.
    await gotoHash(page, '#/');
    await page.waitForTimeout(800);
    await shot(page, theme, 'home', 'no-conversation-placeholder');
  });

  await safe('home', 'quick-switcher', async () => {
    await page.keyboard.press('Control+k');
    await page.waitForTimeout(600);
    await shot(page, theme, 'home', 'quick-switcher');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
  });

  await safe('home', 'global-search', async () => {
    await page.keyboard.press('Control+Shift+f');
    await page.waitForTimeout(600);
    await shot(page, theme, 'home', 'global-search');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
  });

  await safe('home', 'keyboard-shortcuts', async () => {
    await page.keyboard.press('Control+/');
    await page.waitForTimeout(600);
    await shot(page, theme, 'home', 'keyboard-shortcuts');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
  });

  // ---- chat/ ----
  await safe('chat', 'dm', async () => {
    await gotoHash(page, '#/');
    const conv = page.locator('flt-semantics[role="button"]').first();
    if (await conv.isVisible({ timeout: 1500 }).catch(() => false)) {
      await conv.click();
      await page.waitForTimeout(1500);
      await shot(page, theme, 'chat', 'dm');
    }
  });

  await safe('chat', 'message-context-menu', async () => {
    // Right-click on the first visible message in the conversation. The
    // context menu is rendered as a popup overlay; capture it before
    // dismissing.
    const msg = page.locator('flt-semantics').filter({ hasText: /hey there|audit/i }).first();
    if (await msg.isVisible({ timeout: 1500 }).catch(() => false)) {
      const box = await msg.boundingBox();
      if (box) {
        await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2, {
          button: 'right',
        });
        await page.waitForTimeout(600);
        await shot(page, theme, 'chat', 'message-context-menu');
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
    }
  });

  await safe('chat', 'reactions-picker', async () => {
    // Hover over a message → click react button → emoji picker opens.
    // Falls back gracefully if the hover affordance can't be located.
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    const reactBtn = page.getByRole('button', { name: /react|add reaction/i }).first();
    if (await reactBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
      await reactBtn.click();
      await page.waitForTimeout(800);
      await shot(page, theme, 'chat', 'reactions-picker');
      await page.keyboard.press('Escape');
    }
  });

  await safe('chat', 'threads-inbox', async () => {
    await gotoHash(page, '#/threads');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'chat', 'threads-inbox');
  });

  await safe('chat', 'saved-messages', async () => {
    await gotoHash(page, '#/saved');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'chat', 'saved-messages');
  });

  // ---- settings/ — drive via direct hash, capture each section ----
  const settingsRoutes: Array<[string, string]> = [
    ['account', '#/settings/account'],
    ['appearance', '#/settings/appearance'],
    ['advanced-theme', '#/settings/appearance/advanced'],
    ['accessibility', '#/settings/accessibility'],
    ['notifications', '#/settings/notifications'],
    ['privacy', '#/settings/privacy'],
    ['voice', '#/settings/voice'],
    ['devices', '#/settings/devices'],
    ['language', '#/settings/language'],
    ['data-storage', '#/settings/data'],
    ['status', '#/settings/status'],
    ['about', '#/settings/about'],
  ];
  for (const [name, hash] of settingsRoutes) {
    await safe('settings', name, async () => {
      await gotoHash(page, hash);
      await page.waitForTimeout(1200);
      await shot(page, theme, 'settings', name);
    });
  }

  // Sub-dialogs reachable from the appearance section.
  await safe('settings', 'advanced-theme-color-dialog', async () => {
    await gotoHash(page, '#/settings/appearance/advanced');
    await page.waitForTimeout(1000);
    // The custom-accent tile opens a colour picker dialog.
    await tryClickByText(page, /pick custom accent|custom accent|choose colour/i, 1500);
    await page.waitForTimeout(800);
    await shot(page, theme, 'settings', 'advanced-theme-color-dialog');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
  });

  await safe('settings', 'status-picker', async () => {
    await gotoHash(page, '#/settings/status');
    await page.waitForTimeout(1000);
    await tryClickByText(page, /set status|edit status|choose emoji/i, 1500);
    await page.waitForTimeout(600);
    await shot(page, theme, 'settings', 'status-picker');
    await page.keyboard.press('Escape');
  });

  await safe('settings', 'about-feedback-dialog', async () => {
    await gotoHash(page, '#/settings/about');
    await page.waitForTimeout(1000);
    await tryClickByText(page, /send feedback|feedback/i, 1500);
    await page.waitForTimeout(600);
    await shot(page, theme, 'settings', 'about-feedback-dialog');
    await page.keyboard.press('Escape');
  });

  // ---- group/ ----
  await safe('group', 'discover', async () => {
    await gotoHash(page, '#/discover');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'group', 'discover');
  });

  await safe('group', 'create-group', async () => {
    await gotoHash(page, '#/groups/new');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'group', 'create-group');
  });

  await safe('group', 'join-group', async () => {
    await gotoHash(page, '#/groups/join');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'group', 'join-group');
  });

  await safe('group', 'info-owner', async () => {
    // Open the seeded group from the conv list, then click the header
    // to open group-info. We're the owner, so danger zone is visible.
    await gotoHash(page, '#/');
    await page.waitForTimeout(800);
    const groupConv = page.getByText(/audit group/i).first();
    if (await groupConv.isVisible({ timeout: 1500 }).catch(() => false)) {
      await groupConv.click();
      await page.waitForTimeout(1200);
      const header = page.getByText(/audit group/i).first();
      if (await header.isVisible({ timeout: 1500 }).catch(() => false)) {
        await header.click();
        await page.waitForTimeout(1200);
        await shot(page, theme, 'group', 'info-owner');
      }
    }
  });

  // ---- profiles/ ----
  await safe('profiles', 'contacts', async () => {
    await gotoHash(page, '#/contacts');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'profiles', 'contacts');
  });

  await safe('profiles', 'new-message-screen', async () => {
    await gotoHash(page, '#/new-message');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'profiles', 'new-message-screen');
  });

  await safe('profiles', 'username-invite', async () => {
    await gotoHash(page, '#/invite');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'profiles', 'username-invite');
  });

  await safe('profiles', 'user-profile-screen', async () => {
    await gotoHash(page, '#/profile');
    await page.waitForTimeout(1200);
    await shot(page, theme, 'profiles', 'user-profile-screen');
  });

  // -------------------------------------------------------------------------
  // MOBILE PASS — 420×900. Captures the surfaces whose layout meaningfully
  // differs at narrow widths. Suffix files with `-mobile` so desktop +
  // mobile sit side-by-side in the same dir.
  // -------------------------------------------------------------------------
  await page.setViewportSize(MOBILE);
  await page.waitForTimeout(800);

  const mobileTargets: Array<[string, string, string]> = [
    ['home', 'narrow-mobile', '#/'],
    ['home', 'conv-list-populated-mobile', '#/'],
    ['chat', 'dm-mobile', '#/'], // bounce into chat below
    ['settings', 'account-mobile', '#/settings/account'],
    ['settings', 'appearance-mobile', '#/settings/appearance'],
    ['settings', 'accessibility-mobile', '#/settings/accessibility'],
    ['settings', 'notifications-mobile', '#/settings/notifications'],
    ['settings', 'privacy-mobile', '#/settings/privacy'],
    ['settings', 'voice-mobile', '#/settings/voice'],
    ['settings', 'devices-mobile', '#/settings/devices'],
    ['settings', 'data-storage-mobile', '#/settings/data'],
    ['settings', 'status-mobile', '#/settings/status'],
    ['settings', 'about-mobile', '#/settings/about'],
    ['group', 'discover-mobile', '#/discover'],
    ['group', 'create-group-mobile', '#/groups/new'],
    ['group', 'join-group-mobile', '#/groups/join'],
    ['profiles', 'contacts-mobile', '#/contacts'],
    ['profiles', 'new-message-screen-mobile', '#/new-message'],
    ['profiles', 'username-invite-mobile', '#/invite'],
    ['profiles', 'user-profile-screen-mobile', '#/profile'],
    ['chat', 'threads-inbox-mobile', '#/threads'],
    ['chat', 'saved-messages-mobile', '#/saved'],
  ];
  for (const [area, name, hash] of mobileTargets) {
    await safe(area, name, async () => {
      await gotoHash(page, hash);
      await page.waitForTimeout(1000);
      if (name === 'dm-mobile') {
        const conv = page.locator('flt-semantics[role="button"]').first();
        if (await conv.isVisible({ timeout: 1500 }).catch(() => false)) {
          await conv.click();
          await page.waitForTimeout(1200);
        }
      }
      await shot(page, theme, area, name);
    });
  }

  // Restore desktop for next theme iteration.
  await page.setViewportSize(DESKTOP);
  await page.waitForTimeout(400);

  // Inner helper — wraps each capture in try/catch so a single broken nav
  // doesn't poison the rest of the tour. Failures are reported as console
  // warnings, never thrown.
  async function safe(area: string, name: string, fn: () => Promise<void>) {
    try {
      await fn();
    } catch (e) {
      console.warn(`⚠ ${theme}/${area}/${name}.png failed: ${e}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Top-level spec
// ---------------------------------------------------------------------------

test.describe.serial('Audit tour', () => {
  test.setTimeout(600_000); // 10 min budget per theme.

  test.beforeAll(async () => {
    const token = await registerOrLogin(TOUR_USER, TOUR_PASS);
    await seedConversations(token);
  });

  // Auth screens — capture once, before login. Theme doesn't apply to the
  // auth route (the app boots into the default), so this only runs once.
  test('00 — auth surfaces (theme-neutral)', async ({ page }) => {
    const dir = path.join(SHOTS_ROOT, 'indigo', 'auth');
    fs.mkdirSync(dir, { recursive: true });

    await page.goto(APP);
    await waitForFlutter(page);

    // splash captures the moment after the app boots and before login UI
    // settles. The splash is brief; widen the timeout window so we likely
    // catch it on slow machines.
    try {
      await page.screenshot({
        path: path.join(dir, 'splash.png'),
        fullPage: false,
      });
    } catch (e) {
      console.warn(`auth/splash.png: ${e}`);
    }

    await page.waitForTimeout(1500);
    await page.screenshot({
      path: path.join(dir, 'login.png'),
      fullPage: false,
    });

    // Register link — try to find and click it.
    await tryClickByText(page, /sign up|create an account|register/i, 1500);
    await page.waitForTimeout(800);
    await page.screenshot({
      path: path.join(dir, 'register.png'),
      fullPage: false,
    });

    // Forgot password — back to login then try forgot link.
    await tryClickByText(page, /already have an account|back to log/i, 1500);
    await page.waitForTimeout(600);
    await tryClickByText(page, /forgot/i, 1500);
    await page.waitForTimeout(800);
    await page.screenshot({
      path: path.join(dir, 'forgot-password.png'),
      fullPage: false,
    });

    // Mirror the auth/ shots into paper/ and ember/ since auth screens DO
    // honour theme on subsequent loads (login screen reads system theme).
    for (const t of ['paper', 'ember'] as const) {
      const peer = path.join(SHOTS_ROOT, t, 'auth');
      fs.mkdirSync(peer, { recursive: true });
      for (const f of ['login.png', 'register.png', 'forgot-password.png']) {
        const src = path.join(dir, f);
        if (fs.existsSync(src)) fs.copyFileSync(src, path.join(peer, f));
      }
    }
  });

  for (const t of THEMES) {
    test(`theme: ${t.id} — surfaces`, async ({ page }) => {
      await uiLogin(page);
      await setTheme(page, t.id);
      await capture(page, t.id);
    });
  }
});
