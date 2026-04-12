/**
 * E2E test using ARIA/Semantics locators for Flutter web (CanvasKit).
 *
 * Flutter web renders to <canvas>, so DOM selectors don't work.
 * Instead, we enable SemanticsBinding.instance.ensureSemantics() in main.dart
 * and use Playwright's getByRole locators which map to the accessibility tree.
 *
 * IMPORTANT: Flutter exposes Semantics labels as button text content (not
 * aria-label), so use getByRole('button', { name: '...' }) not getByLabel().
 *
 * Requires:
 *   - Server running on :8080 (or ECHO_SERVER env var)
 *   - Flutter web build served on :8081 (or ECHO_URL env var)
 *   - Pass ?server= to override the Flutter app's default server URL
 *
 * Run: npx playwright test tests/e2e/semantics_e2e.spec.ts --headed
 */
import { test, expect, Page } from '@playwright/test';

const WEB_URL = process.env.ECHO_URL || 'http://localhost:8081';
const SERVER_URL = process.env.ECHO_SERVER || 'http://localhost:8080';
const APP = `${WEB_URL}/?server=${encodeURIComponent(SERVER_URL)}`;
const SS_DIR = 'tests/e2e/test-results/semantics';

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS_DIR}/${name}.png`, fullPage: true });
}

/** Wait for Flutter to boot and the semantics tree to appear. */
async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 20000 });
  // Extra frame for semantics to populate
  await page.waitForTimeout(2000);
}

/** Dismiss any modal dialogs (e.g. "Welcome to Echo"). */
async function dismissDialogs(page: Page) {
  for (const label of [/got it/i, /close/i, /dismiss/i]) {
    const btn = page.getByRole('button', { name: label });
    if (await btn.isVisible({ timeout: 2000 }).catch(() => false)) {
      await btn.click();
      await page.waitForTimeout(500);
    }
  }
}

/** Register a new user via the UI. */
async function register(page: Page, username: string, password: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  await page.getByRole('button', { name: /create an account/i }).click();
  await page.waitForTimeout(1500);

  // Fill registration form. Use Tab to navigate between fields because
  // Flutter web's password fields have quirks with fill() and click().
  await page.getByLabel('Username').click();
  await page.keyboard.type(username, { delay: 10 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 10 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 10 });
  await page.waitForTimeout(300);
  await page.getByRole('button', { name: /register/i }).click();

  await page.waitForTimeout(6000);
  await dismissDialogs(page);
}

/** Login via the UI. */
async function login(page: Page, username: string, password: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  // Flutter web password fields ignore fill(). Use focus+type via keyboard
  // which feeds into Flutter's text editing channel correctly.
  const userInput = page.locator('input[aria-label="Username"]');
  await userInput.focus();
  await page.keyboard.type(username, { delay: 10 });
  const passInput = page.locator('input[aria-label="Password"]');
  await passInput.focus();
  await page.keyboard.type(password, { delay: 10 });
  await page.getByRole('button', { name: /login/i }).click();

  await page.waitForTimeout(6000);
  await dismissDialogs(page);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Flutter Semantics E2E', () => {
  test.setTimeout(120000);

  test('login screen has accessible form fields', async ({ page }) => {
    await page.goto(APP);
    await waitForFlutter(page);
    await ss(page, '01-login-screen');

    // Verify interactive elements are accessible via ARIA
    await expect(page.getByLabel('Username')).toBeVisible();
    await expect(page.getByLabel('Password')).toBeVisible();
    await expect(page.getByRole('button', { name: /login/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /create an account/i })).toBeVisible();

    // Type into fields
    await page.getByLabel('Username').fill('testuser');
    await page.getByLabel('Password').fill('testpass');
    await ss(page, '02-login-filled');
  });

  test('register -> land on home with tabs', async ({ page }) => {
    const ts = Date.now().toString().slice(-5);
    await register(page, `e2e_${ts}`, 'TestPass123!');
    await ss(page, '03-after-register');

    // Verify sidebar tabs are accessible
    const chatsTab = page.getByRole('button', { name: /chats tab/i });
    await expect(chatsTab).toBeVisible({ timeout: 10000 });
    await ss(page, '04-home-screen');
  });

  test('sidebar tab navigation via ARIA', async ({ page }) => {
    const ts = Date.now().toString().slice(-5);
    await register(page, `e2e_tabs_${ts}`, 'TestPass123!');

    // Chats tab should be visible by default
    const chatsTab = page.getByRole('button', { name: /chats tab/i });
    await expect(chatsTab).toBeVisible({ timeout: 10000 });
    await ss(page, '05-tabs-chats');

    // Navigate to Contacts
    const contactsTab = page.getByRole('button', { name: /contacts tab/i });
    await contactsTab.click();
    await page.waitForTimeout(500);
    await ss(page, '06-tabs-contacts');

    // Navigate to Groups
    const groupsTab = page.getByRole('button', { name: /groups tab/i });
    await groupsTab.click();
    await page.waitForTimeout(500);
    await ss(page, '07-tabs-groups');

    // Back to Chats
    await chatsTab.click();
    await page.waitForTimeout(500);
  });

  // Known limitation: Flutter web password fields don't reliably accept
  // input in secondary browser contexts. This test is skipped until
  // Patrol 4.0 web support is available as an alternative.
  test.skip('two-user register + verify home', async ({ browser, request }) => {
    const ts = Date.now().toString().slice(-5);
    const user1 = `e2e_a_${ts}`;
    const user2 = `e2e_b_${ts}`;
    const pw = 'TestPass123!';

    // Register both users via API to avoid rate limiting
    for (const u of [user1, user2]) {
      await request.post(`${SERVER_URL}/api/auth/register`, {
        data: { username: u, password: pw },
      });
    }

    // Login both via UI
    const ctx1 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const p1 = await ctx1.newPage();
    const p2 = await ctx2.newPage();

    await login(p1, user1, pw);
    await login(p2, user2, pw);

    // Verify both landed on home
    await expect(p1.getByRole('button', { name: /chats tab/i })).toBeVisible({ timeout: 10000 });
    await expect(p2.getByRole('button', { name: /chats tab/i })).toBeVisible({ timeout: 10000 });

    await ss(p1, '08-user1-home');
    await ss(p2, '09-user2-home');

    // User 1: navigate to Contacts tab
    await p1.getByRole('button', { name: /contacts tab/i }).click();
    await p1.waitForTimeout(1000);
    await ss(p1, '10-user1-contacts');

    await ctx1.close();
    await ctx2.close();
  });
});
