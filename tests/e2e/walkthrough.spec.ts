import { test, Page } from '@playwright/test';
import { execSync } from 'child_process';

const SERVER = 'http://localhost:8080';
const APP = 'http://localhost:8081';
const SS = 'tests/e2e/test-results/walkthrough';

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function login(page: Page, username: string, password: string) {
  await page.goto(APP);
  await page.waitForTimeout(4000);
  const vp = page.viewportSize()!;
  await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
  await page.waitForTimeout(200);
  await page.keyboard.type(username, { delay: 30 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 30 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(5000);
}

test.describe('Full App Walkthrough', () => {
  test.setTimeout(120000);

  test.beforeAll(async () => {
    // Seed via REST + websocat (Node WebSocket not available)
    const alice = await fetch(`${SERVER}/api/auth/register`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'walk_alice', password: 'password123' }),
    }).then(r => r.json()).catch(() => null);

    const bob = await fetch(`${SERVER}/api/auth/register`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'walk_bob', password: 'password456' }),
    }).then(r => r.json()).catch(() => null);

    const at = alice?.access_token || (await fetch(`${SERVER}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'walk_alice', password: 'password123' }),
    }).then(r => r.json())).access_token;

    const bt = bob?.access_token || (await fetch(`${SERVER}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'walk_bob', password: 'password456' }),
    }).then(r => r.json())).access_token;

    const bi = (await fetch(`${SERVER}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'walk_bob', password: 'password456' }),
    }).then(r => r.json())).user_id;

    // Make contacts
    try {
      const c = await fetch(`${SERVER}/api/contacts/request`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${at}` },
        body: JSON.stringify({ username: 'walk_bob' }),
      }).then(r => r.json());
      if (c.contact_id) {
        await fetch(`${SERVER}/api/contacts/accept`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${bt}` },
          body: JSON.stringify({ contact_id: c.contact_id }),
        });
      }
    } catch (_) {}

    // Pre-send messages via websocat
    try {
      const msg1 = JSON.stringify({ type: 'send_message', to_user_id: bi, content: 'Hey Bob!' });
      const msg2 = JSON.stringify({ type: 'send_message', to_user_id: bi, content: 'Want to test the app?' });
      execSync(`echo '${msg1}' | timeout 3 websocat "ws://localhost:8080/ws?token=${at}" || true`, { timeout: 5000 });
      execSync(`echo '${msg2}' | timeout 3 websocat "ws://localhost:8080/ws?token=${at}" || true`, { timeout: 5000 });
    } catch (_) {}
  });

  test('walkthrough', async ({ browser }) => {
    const aliceCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const bobCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const alice = await aliceCtx.newPage();
    const bob = await bobCtx.newPage();

    // === 1. LOGIN SCREEN ===
    await alice.goto(APP);
    await alice.waitForTimeout(4000);
    await ss(alice, '01-login-screen');

    // === 2. REGISTER SCREEN ===
    await alice.mouse.click(210, 470); // "Create an account" link
    await alice.waitForTimeout(2000);
    await ss(alice, '02-register-screen');

    // === 3. LOGIN AS ALICE ===
    await login(alice, 'walk_alice', 'password123');
    await ss(alice, '03-alice-conversations');

    // === 4. LOGIN AS BOB ===
    await login(bob, 'walk_bob', 'password456');
    await ss(bob, '04-bob-conversations');

    // === 5. ALICE CLICKS CONVERSATION WITH BOB ===
    await alice.mouse.click(210, 85);
    await alice.waitForTimeout(3000);
    await ss(alice, '05-alice-chat');

    // === 6. BOB CLICKS CONVERSATION WITH ALICE ===
    await bob.mouse.click(210, 85);
    await bob.waitForTimeout(3000);
    await ss(bob, '06-bob-chat');

    // === 7. BOB TYPES A MESSAGE ===
    await bob.mouse.click(210, 710);
    await bob.waitForTimeout(300);
    await bob.keyboard.type('Hello Alice! The app looks great!', { delay: 20 });
    await ss(bob, '07-bob-typing');

    // === 8. BOB SENDS ===
    await bob.keyboard.press('Enter');
    await bob.waitForTimeout(2000);
    await ss(bob, '08-bob-sent');

    // === 9. ALICE SEES THE MESSAGE ===
    await alice.waitForTimeout(2000);
    await ss(alice, '09-alice-received');

    // === 10. ALICE REPLIES ===
    await alice.mouse.click(210, 710);
    await alice.waitForTimeout(300);
    await alice.keyboard.type('Thanks Bob! E2E encrypted!', { delay: 20 });
    await alice.keyboard.press('Enter');
    await alice.waitForTimeout(2000);
    await ss(alice, '10-alice-replied');

    // === 11. BOB SEES REPLY ===
    await bob.waitForTimeout(2000);
    await ss(bob, '11-bob-sees-reply');

    // === 12. ALICE GOES BACK ===
    await alice.mouse.click(25, 28);
    await alice.waitForTimeout(1500);
    await ss(alice, '12-alice-back-to-conversations');

    // === 13. BOB GOES BACK ===
    await bob.mouse.click(25, 28);
    await bob.waitForTimeout(1500);
    await ss(bob, '13-bob-back-to-conversations');

    // === 14. ALICE OPENS CONTACTS ===
    await alice.mouse.click(320, 28); // People icon
    await alice.waitForTimeout(2000);
    await ss(alice, '14-alice-contacts');

    await aliceCtx.close();
    await bobCtx.close();
  });
});
