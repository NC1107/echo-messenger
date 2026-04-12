/**
 * E2E test using ARIA/Semantics locators for Flutter web (CanvasKit).
 *
 * Flutter web renders to <canvas>, so DOM selectors don't work.
 * Instead, we enable SemanticsBinding.instance.ensureSemantics() in main.dart
 * and use Playwright's getByRole/getByLabel locators which map to the
 * accessibility tree Flutter generates.
 *
 * Run: npx playwright test tests/e2e/semantics_e2e.spec.ts
 */
import { test, expect, Page } from '@playwright/test';

const APP = process.env.ECHO_URL || 'http://localhost:8081';
const SCREENSHOT_DIR = 'tests/e2e/test-results/semantics';

async function screenshot(page: Page, name: string) {
  await page.screenshot({ path: `${SCREENSHOT_DIR}/${name}.png`, fullPage: true });
}

/**
 * Wait for Flutter to finish rendering and the semantics tree to be available.
 * Flutter web takes a few seconds to boot + render the initial frame.
 */
async function waitForFlutter(page: Page, timeoutMs = 15000) {
  // Wait for the flutter-view element and flt-semantics nodes to appear
  await page.waitForSelector('flt-semantics', { timeout: timeoutMs });
}

/**
 * Register a new user through the UI using semantics locators.
 */
async function registerUser(page: Page, username: string, password: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  // Click "Create an account" link
  await page.getByRole('link', { name: /create an account/i }).click();
  await page.waitForTimeout(1000);

  // Fill registration form
  await page.getByRole('textbox', { name: /username/i }).fill(username);
  await page.getByRole('textbox', { name: /^password$/i }).fill(password);
  await page.getByRole('textbox', { name: /confirm password/i }).fill(password);
  await page.getByRole('button', { name: /register/i }).click();

  // Wait for navigation to onboarding or home
  await page.waitForTimeout(5000);
}

/**
 * Login through the UI using semantics locators.
 */
async function loginUser(page: Page, username: string, password: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  await page.getByRole('textbox', { name: /username/i }).fill(username);
  await page.getByRole('textbox', { name: /password/i }).fill(password);
  await page.getByRole('button', { name: /login/i }).click();

  // Wait for home screen
  await page.waitForTimeout(5000);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Flutter Semantics E2E', () => {
  test.setTimeout(120000);

  test('login screen has accessible form fields', async ({ page }) => {
    await page.goto(APP);
    await waitForFlutter(page);
    await screenshot(page, '01-login-screen');

    // Verify form fields are accessible via ARIA
    const usernameField = page.getByRole('textbox', { name: /username/i });
    const passwordField = page.getByRole('textbox', { name: /password/i });
    const loginButton = page.getByRole('button', { name: /login/i });

    await expect(usernameField).toBeVisible();
    await expect(passwordField).toBeVisible();
    await expect(loginButton).toBeVisible();

    // Verify we can type into fields
    await usernameField.fill('testuser');
    await passwordField.fill('testpass');
    await screenshot(page, '02-login-filled');
  });

  test('register -> skip onboarding -> land on home', async ({ page }) => {
    const ts = Date.now().toString().slice(-5);
    const username = `e2e_${ts}`;
    const password = 'TestPass123!';

    await registerUser(page, username, password);
    await screenshot(page, '03-after-register');

    // Skip onboarding if present
    const skipButton = page.getByRole('button', { name: /skip/i });
    if (await skipButton.isVisible({ timeout: 3000 }).catch(() => false)) {
      // Click through onboarding pages
      for (let i = 0; i < 4; i++) {
        const skip = page.getByRole('button', { name: /skip/i });
        if (await skip.isVisible({ timeout: 1000 }).catch(() => false)) {
          await skip.click();
          await page.waitForTimeout(500);
          break;
        }
        const next = page.getByRole('button', { name: /next/i });
        if (await next.isVisible({ timeout: 1000 }).catch(() => false)) {
          await next.click();
          await page.waitForTimeout(500);
        }
      }
    }

    await page.waitForTimeout(2000);
    await screenshot(page, '04-home-screen');

    // Verify we're on the home screen — sidebar tabs should be visible
    const chatsTab = page.getByLabel('Chats tab');
    await expect(chatsTab).toBeVisible({ timeout: 10000 });
  });

  test('sidebar tabs are navigable via ARIA', async ({ page }) => {
    const ts = Date.now().toString().slice(-5);
    await registerUser(page, `e2e_tabs_${ts}`, 'TestPass123!');

    // Skip onboarding
    const skipBtn = page.getByRole('button', { name: /skip/i });
    if (await skipBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
      await skipBtn.click();
      await page.waitForTimeout(2000);
    }

    await screenshot(page, '05-tabs-chats');

    // Navigate tabs
    const contactsTab = page.getByLabel('Contacts tab');
    await expect(contactsTab).toBeVisible({ timeout: 10000 });
    await contactsTab.click();
    await page.waitForTimeout(500);
    await screenshot(page, '06-tabs-contacts');

    const groupsTab = page.getByLabel('Groups tab');
    await groupsTab.click();
    await page.waitForTimeout(500);
    await screenshot(page, '07-tabs-groups');

    // Switch back to chats
    const chatsTab = page.getByLabel('Chats tab');
    await chatsTab.click();
    await page.waitForTimeout(500);
  });

  test('two-user DM flow via ARIA locators', async ({ browser }) => {
    const ts = Date.now().toString().slice(-5);
    const user1 = `e2e_dm1_${ts}`;
    const user2 = `e2e_dm2_${ts}`;
    const password = 'TestPass123!';

    // Create two browser contexts (two users)
    const ctx1 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const p1 = await ctx1.newPage();
    const p2 = await ctx2.newPage();

    // Register both users
    await registerUser(p1, user1, password);
    await registerUser(p2, user2, password);

    // Skip onboarding for both
    for (const p of [p1, p2]) {
      const skip = p.getByRole('button', { name: /skip/i });
      if (await skip.isVisible({ timeout: 5000 }).catch(() => false)) {
        await skip.click();
        await p.waitForTimeout(2000);
      }
    }

    // User 1: go to Contacts tab
    const contactsTab1 = p1.getByLabel('Contacts tab');
    await expect(contactsTab1).toBeVisible({ timeout: 10000 });
    await contactsTab1.click();
    await p1.waitForTimeout(1000);

    // User 1: search for user2 by username
    // The contacts screen has a search field
    const searchField = p1.getByRole('textbox', { name: /search/i });
    if (await searchField.isVisible({ timeout: 3000 }).catch(() => false)) {
      await searchField.fill(user2);
      await p1.waitForTimeout(2000);
    }

    await screenshot(p1, '08-user1-contacts');
    await screenshot(p2, '09-user2-home');

    // User 1: send a DM message (if a conversation exists)
    const chatsTab1 = p1.getByLabel('Chats tab');
    await chatsTab1.click();
    await p1.waitForTimeout(1000);

    // Try to find and click the message input
    const msgInput = p1.getByRole('textbox', { name: /type a message/i });
    if (await msgInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await msgInput.fill('Hello from Playwright via ARIA!');

      // Click send button
      const sendBtn = p1.getByLabel('Send message');
      await expect(sendBtn).toBeVisible();
      await sendBtn.click();
      await p1.waitForTimeout(2000);
      await screenshot(p1, '10-message-sent');
    }

    await ctx1.close();
    await ctx2.close();
  });
});
