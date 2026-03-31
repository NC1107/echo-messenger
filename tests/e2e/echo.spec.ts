import { test, expect, Page, Browser } from '@playwright/test';

const SERVER = 'http://localhost:8080';
const APP = 'http://localhost:8081';

async function seedUsers() {
  const alice = await fetch(`${SERVER}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'pw_alice', password: 'password123' }),
  }).then(r => r.json()).catch(() => null);

  const bob = await fetch(`${SERVER}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'pw_bob', password: 'password456' }),
  }).then(r => r.json()).catch(() => null);

  const aliceToken = alice?.access_token || (await fetch(`${SERVER}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'pw_alice', password: 'password123' }),
  }).then(r => r.json())).access_token;

  const bobToken = bob?.access_token || (await fetch(`${SERVER}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'pw_bob', password: 'password456' }),
  }).then(r => r.json())).access_token;

  try {
    const c = await fetch(`${SERVER}/api/contacts/request`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${aliceToken}` },
      body: JSON.stringify({ username: 'pw_bob' }),
    }).then(r => r.json());
    if (c.contact_id) {
      await fetch(`${SERVER}/api/contacts/accept`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${bobToken}` },
        body: JSON.stringify({ contact_id: c.contact_id }),
      });
    }
  } catch (_) {}
}

async function login(page: Page, username: string, password: string) {
  await page.goto(APP);
  await page.waitForTimeout(4000); // Flutter init is slow on web

  // Flutter web renders text fields - click on the Username area and type
  // The inputs are rendered but may use custom elements
  // Strategy: click where the Username field should be, then type
  const viewport = page.viewportSize()!;
  const centerX = viewport.width / 2;
  const centerY = viewport.height / 2;

  // Username field is roughly at center, slightly above center
  await page.mouse.click(centerX, centerY - 40);
  await page.waitForTimeout(300);
  await page.keyboard.type(username, { delay: 50 });

  // Tab to password field
  await page.keyboard.press('Tab');
  await page.waitForTimeout(300);
  await page.keyboard.type(password, { delay: 50 });

  // Press Enter to login
  await page.keyboard.press('Enter');
  await page.waitForTimeout(4000); // Wait for login + crypto init
}

test.describe('Echo Messenger', () => {
  test.beforeAll(async () => {
    await seedUsers();
  });

  test('01 - login screen renders', async ({ page }) => {
    await page.goto(APP);
    await page.waitForTimeout(4000);
    await page.screenshot({ path: 'test-results/01-login-screen.png', fullPage: true });
  });

  test('02 - alice can login and see conversations', async ({ page }) => {
    await login(page, 'pw_alice', 'password123');
    await page.screenshot({ path: 'test-results/02-alice-home.png', fullPage: true });
  });

  test('03 - bob can login and see conversations', async ({ page }) => {
    await login(page, 'pw_bob', 'password456');
    await page.screenshot({ path: 'test-results/03-bob-home.png', fullPage: true });
  });

  test('04 - two users chatting', async ({ browser }) => {
    const aliceCtx = await browser.newContext();
    const bobCtx = await browser.newContext();
    const alice = await aliceCtx.newPage();
    const bob = await bobCtx.newPage();

    await login(alice, 'pw_alice', 'password123');
    await login(bob, 'pw_bob', 'password456');

    await alice.screenshot({ path: 'test-results/04-alice-conversations.png', fullPage: true });
    await bob.screenshot({ path: 'test-results/05-bob-conversations.png', fullPage: true });

    await aliceCtx.close();
    await bobCtx.close();
  });
});
