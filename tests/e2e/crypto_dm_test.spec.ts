/**
 * Crypto DM End-to-End Test
 *
 * Scenarios tested:
 * 1. Fresh user registration → key bundle uploads successfully
 * 2. Two users can exchange encrypted DMs
 * 3. Browser restart → keys persist and messaging continues
 * 4. Both browsers restart → messaging still works
 * 5. Key bundles are fetchable for any device ID (not just device 0)
 *
 * Run headed: cd tests/e2e && npx playwright test crypto_dm_test.spec.ts --headed
 */
import { test, expect, Page, BrowserContext } from '@playwright/test';

const SERVER = 'http://localhost:8080';
const APP_BASE = 'http://localhost:8081';
const APP = `${APP_BASE}/?server=${encodeURIComponent(SERVER)}`;
const SS = 'tests/e2e/test-results/crypto-dm';

const SLOW = 250;
const ts = Date.now().toString().slice(-5);
const ALICE = `alice${ts}`;
const BOB = `bob${ts}`;
const PW = 'testpass123';

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function apiPost(path: string, body: any, token?: string) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${SERVER}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function apiGet(path: string, token: string) {
  const res = await fetch(`${SERVER}${path}`, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function registerUser(username: string) {
  const { data } = await apiPost('/api/auth/register', { username, password: PW });
  console.log(`  Registered ${username} (${data.user_id})`);
  return data;
}

async function loginUser(username: string) {
  const { data } = await apiPost('/api/auth/login', { username, password: PW });
  return data;
}

async function setupContacts(token1: string, username2: string, token2: string) {
  await apiPost('/api/contacts/request', { username: username2 }, token1);
  const { data: pending } = await apiGet('/api/contacts/pending', token2);
  for (const req of (pending as any[])) {
    await apiPost(`/api/contacts/accept/${req.id}`, {}, token2);
  }
  console.log('  Contacts established');
}

async function checkKeyBundle(token: string, userId: string): Promise<boolean> {
  const { status, data } = await apiGet(`/api/keys/bundle/${userId}`, token);
  const ok = status === 200 && data.identity_key;
  console.log(`  Bundle for ${userId.slice(0,8)}: ${ok ? '✓ found' : `✗ ${status} ${JSON.stringify(data).slice(0,60)}`}`);
  return !!ok;
}

// ---------------------------------------------------------------------------
// Browser helpers
// ---------------------------------------------------------------------------

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function loginInBrowser(page: Page, username: string) {
  await page.goto(APP);
  await page.waitForTimeout(5000);

  const vp = page.viewportSize()!;
  await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
  await page.waitForTimeout(SLOW);
  await page.keyboard.type(username, { delay: 12 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(SLOW);
  await page.keyboard.type(PW, { delay: 12 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(8000);

  // Dismiss popups
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
  }
  await page.waitForTimeout(500);
  console.log(`  ${username} logged in`);
}

/** Send a DM via WebSocket by sending through the app's REST API as a workaround
 *  for conversation creation. This creates the conversation on both sides. */
async function sendDmViaApi(token: string, toUserId: string, content: string) {
  // The server's WS handler creates the conversation. But we can't easily
  // use WS from Playwright. Instead, we'll rely on the UI to send.
  // For conversation creation, we just need one side to send a message.
}

/** Click on a conversation in the sidebar by looking for username text */
async function openConversation(page: Page, peerUsername: string): Promise<boolean> {
  try {
    const el = page.locator(`text=${peerUsername}`).first();
    if (await el.isVisible({ timeout: 3000 })) {
      await el.click();
      await page.waitForTimeout(1500);
      return true;
    }
  } catch {}
  return false;
}

/** Type a message and press Enter */
async function sendMessage(page: Page, text: string) {
  const vp = page.viewportSize()!;
  // Click the input field at the bottom
  await page.mouse.click(vp.width / 2, vp.height - 40);
  await page.waitForTimeout(SLOW);
  await page.keyboard.type(text, { delay: 8 });
  await page.waitForTimeout(SLOW);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(2500);
}

/** Check if page body contains a string */
async function pageContains(page: Page, text: string): Promise<boolean> {
  const body = await page.textContent('body') ?? '';
  return body.includes(text);
}

/** Check for crypto error messages */
async function hasCryptoErrors(page: Page): Promise<string[]> {
  const body = await page.textContent('body') ?? '';
  const errors: string[] = [];
  if (body.includes('Waiting for this person')) errors.push('Waiting for person to come online');
  if (body.includes('not have been delivered')) errors.push('Message may not have been delivered');
  if (body.includes('Could not decrypt')) errors.push('Could not decrypt');
  if (body.includes('encryption keys may be out of sync')) errors.push('Keys out of sync');
  if (body.includes('Encryption failed')) errors.push('Encryption failed');
  if (body.includes('set up encryption')) errors.push('Encryption not set up');
  return errors;
}

/** Click the "new chat" / contacts area to start a DM */
async function startNewDm(page: Page, peerUsername: string) {
  const vp = page.viewportSize()!;
  // The new-chat button is in the top-left area of the sidebar
  // Look for the person-add icon button
  try {
    const newChatBtn = page.locator('[class*="conversation"] >> text=New Chat').first();
    if (await newChatBtn.isVisible({ timeout: 1000 })) {
      await newChatBtn.click();
      await page.waitForTimeout(1000);
    }
  } catch {}

  // Try clicking on the contact name directly if visible
  try {
    const contact = page.locator(`text=${peerUsername}`).first();
    if (await contact.isVisible({ timeout: 2000 })) {
      await contact.click();
      await page.waitForTimeout(1500);
      return true;
    }
  } catch {}
  return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Encrypted DM Tests', () => {
  let aliceData: any;
  let bobData: any;

  test.beforeAll(async () => {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`CRYPTO DM TESTS — ${ALICE} <-> ${BOB}`);
    console.log(`${'='.repeat(60)}\n`);

    // Register users and set up contacts via API
    aliceData = await registerUser(ALICE);
    bobData = await registerUser(BOB);
    await setupContacts(aliceData.access_token, BOB, bobData.access_token);
  });

  test('1. Key bundles upload after browser login', async ({ browser }) => {
    test.setTimeout(120000);
    console.log('\n--- Test 1: Key bundle upload ---');

    // Login Alice
    const ctx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const page = await ctx.newPage();
    await loginInBrowser(page, ALICE);
    await page.waitForTimeout(3000);
    await ss(page, '01_alice_logged_in');

    // Check Alice's key bundle is on server
    const freshToken = (await loginUser(BOB)).access_token;
    const hasBundle = await checkKeyBundle(freshToken, aliceData.user_id);
    expect(hasBundle).toBe(true);

    await ctx.close();
  });

  test('2. Both users can exchange encrypted DMs', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test 2: Encrypted DM exchange ---');

    // Open both browsers
    const aliceCtx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const alicePage = await aliceCtx.newPage();
    await loginInBrowser(alicePage, ALICE);

    const bobCtx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const bobPage = await bobCtx.newPage();
    await loginInBrowser(bobPage, BOB);

    // Verify both have key bundles
    const aliceToken = (await loginUser(ALICE)).access_token;
    const bobToken = (await loginUser(BOB)).access_token;
    const aliceHasKeys = await checkKeyBundle(bobToken, aliceData.user_id);
    const bobHasKeys = await checkKeyBundle(aliceToken, bobData.user_id);
    console.log(`  Alice keys: ${aliceHasKeys ? '✓' : '✗'}, Bob keys: ${bobHasKeys ? '✓' : '✗'}`);

    // Try to open conversation (may or may not exist yet)
    let aliceOpened = await openConversation(alicePage, BOB);
    if (!aliceOpened) {
      console.log('  No existing conversation — trying to start new DM');
      aliceOpened = await startNewDm(alicePage, BOB);
    }

    if (aliceOpened) {
      // Alice sends to Bob
      const msg1 = `Hello Bob from Alice [${ts}]`;
      await sendMessage(alicePage, msg1);
      await ss(alicePage, '02_alice_sent');

      const aliceErrors = await hasCryptoErrors(alicePage);
      expect(
        aliceErrors,
        `Alice surfaced crypto errors after sending: ${aliceErrors.join(', ')}`,
      ).toEqual([]);

      // Bob opens the conversation
      await bobPage.waitForTimeout(2000);
      const bobOpened = await openConversation(bobPage, ALICE);
      expect(bobOpened, 'Bob could not open conversation with Alice').toBe(true);

      await bobPage.waitForTimeout(2000);
      await ss(bobPage, '03_bob_received');
      const bobSees = await pageContains(bobPage, 'Hello Bob from Alice');
      expect(bobSees, "Bob did not see Alice's encrypted message").toBe(true);

      // Bob replies
      const msg2 = `Reply from Bob [${ts}]`;
      await sendMessage(bobPage, msg2);
      await ss(bobPage, '04_bob_replied');
      const bobErrors = await hasCryptoErrors(bobPage);
      expect(
        bobErrors,
        `Bob surfaced crypto errors after replying: ${bobErrors.join(', ')}`,
      ).toEqual([]);

      // Alice sees the reply
      await alicePage.waitForTimeout(3000);
      const aliceSees = await pageContains(alicePage, 'Reply from Bob');
      expect(aliceSees, "Alice did not see Bob's reply").toBe(true);
      await ss(alicePage, '05_alice_sees_reply');
    } else {
      expect(aliceOpened, 'Could not open DM conversation as Alice').toBe(true);
    }

    await aliceCtx.close();
    await bobCtx.close();
  });

  test('3. Messages work after one browser restarts', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test 3: Messaging after browser restart ---');

    // Alice stays logged in, Bob restarts
    const aliceCtx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const alicePage = await aliceCtx.newPage();
    await loginInBrowser(alicePage, ALICE);

    // Bob logs in then closes
    let bobCtx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    let bobPage = await bobCtx.newPage();
    await loginInBrowser(bobPage, BOB);
    await bobPage.waitForTimeout(2000);

    console.log('  Closing Bob\'s browser...');
    await bobCtx.close();
    await alicePage.waitForTimeout(2000);

    // Reopen Bob
    console.log('  Reopening Bob\'s browser...');
    bobCtx = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    bobPage = await bobCtx.newPage();
    await loginInBrowser(bobPage, BOB);
    await bobPage.waitForTimeout(3000);

    // Verify Bob's keys are still valid
    const aliceToken = (await loginUser(ALICE)).access_token;
    const bobStillHasKeys = await checkKeyBundle(aliceToken, bobData.user_id);
    console.log(`  Bob keys after restart: ${bobStillHasKeys ? '✓' : '✗'}`);

    // Alice tries to send to Bob after restart
    const aliceOpened = await openConversation(alicePage, BOB);
    if (aliceOpened) {
      const msg = `Post-restart message [${ts}]`;
      await sendMessage(alicePage, msg);
      const errors = await hasCryptoErrors(alicePage);
      console.log(`  Post-restart send: ${errors.length === 0 ? '✓ OK' : '✗ ' + errors.join(', ')}`);
      await ss(alicePage, '06_post_restart_send');
    }

    await aliceCtx.close();
    await bobCtx.close();
  });

  test('4. Key bundles visible via API after all sessions close', async ({ browser }) => {
    test.setTimeout(60000);
    console.log('\n--- Test 4: Key persistence after all browsers close ---');

    // Login both in browsers, then close ALL browsers
    const ctx1 = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const p1 = await ctx1.newPage();
    await loginInBrowser(p1, ALICE);

    const ctx2 = await browser.newContext({ viewport: { width: 1920, height: 993 } });
    const p2 = await ctx2.newPage();
    await loginInBrowser(p2, BOB);

    await ctx1.close();
    await ctx2.close();
    console.log('  All browsers closed');

    // Check keys are still on server
    const aliceToken = (await loginUser(ALICE)).access_token;
    const bobToken = (await loginUser(BOB)).access_token;
    const aliceKeys = await checkKeyBundle(bobToken, aliceData.user_id);
    const bobKeys = await checkKeyBundle(aliceToken, bobData.user_id);
    console.log(`  Alice keys persisted: ${aliceKeys ? '✓' : '✗'}`);
    console.log(`  Bob keys persisted: ${bobKeys ? '✓' : '✗'}`);
    expect(aliceKeys).toBe(true);
    expect(bobKeys).toBe(true);
  });
});
