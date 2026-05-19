/**
 * Encryption-roundtrip validation for fresh groups.
 *
 * Asserts that two parties in a freshly-created encrypted group can read
 * each other's messages as plaintext. Specifically protects against the
 * "stale TOFU identity wraps an unwrappable envelope" regression: when
 * the seed wraps the group key under an identity that doesn't match the
 * recipient's current private key, every group message after that comes
 * out as "Message could not be decrypted" on the receiver side and as
 * raw `GRP1:...` ciphertext in the sender's own conversation preview.
 *
 * The create-group step MUST go through the UI (and not the REST API)
 * because the seed-on-create runs in the client's createGroup handler
 * after a 201 — an API-created group lands on the server without any
 * envelope, and the wedged-recovery branch only fires from the refresh
 * banner. Driving the UI exercises the actual fix.
 *
 * Env vars:
 *   ECHO_SERVER  default: http://localhost:8080
 *   ECHO_URL     default: http://localhost:8081
 *
 * Run against prod:
 *   ECHO_SERVER=https://echo-messenger.us ECHO_URL=https://echo-messenger.us \
 *     npx playwright test tests/e2e/group_encryption_roundtrip.spec.ts \
 *     --project=maintained
 */
import { test, expect, Page } from '@playwright/test';

const SERVER = process.env.ECHO_SERVER || 'http://localhost:8080';
const WEB_URL = process.env.ECHO_URL || 'http://localhost:8081';
const APP = `${WEB_URL}/?server=${encodeURIComponent(SERVER)}`;
const SS = 'tests/e2e/test-results/group-encryption-roundtrip';

const ts = Date.now().toString().slice(-6);
const ALICE = `enca${ts}`;
const BOB = `encb${ts}`;
const PW = 'TestPass123!';
const GROUP_NAME = `EncRT${ts}`;

// ---------------------------------------------------------------------------
// API helpers — registration + contact-acceptance happen out-of-band so the
// browser-driven part of the test focuses purely on group-create + send.
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
    headers: { Authorization: `Bearer ${token}` },
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function registerOrLogin(username: string) {
  const reg = await apiPost('/api/auth/register', { username, password: PW });
  if (reg.status === 201 && reg.data?.access_token) return reg.data;
  const login = await apiPost('/api/auth/login', { username, password: PW });
  if (login.data?.access_token) return login.data;
  // Surface the actual server response so CI logs aren't just "undefined".
  throw new Error(
    `registerOrLogin(${username}) failed: ` +
      `register=${reg.status} ${JSON.stringify(reg.data)} ` +
      `login=${login.status} ${JSON.stringify(login.data)}`,
  );
}

async function serverIsHealthy(): Promise<boolean> {
  try {
    const res = await fetch(`${SERVER}/api/health`, {
      signal: AbortSignal.timeout(3000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function establishContact(alice: any, bob: any) {
  await apiPost('/api/contacts/request', { username: BOB }, alice.access_token);
  const { data: pending } = await apiGet(
    '/api/contacts/pending',
    bob.access_token,
  );
  for (const req of pending as any[]) {
    await apiPost(
      '/api/contacts/accept',
      { contact_id: req.id },
      bob.access_token,
    );
  }
}

// ---------------------------------------------------------------------------
// Flutter/web helpers
// ---------------------------------------------------------------------------

async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 30_000 });
  await page.waitForTimeout(2000);
}

async function dismissPopups(page: Page) {
  for (const label of [/got it/i, /close/i, /dismiss/i, /not now/i]) {
    const btn = page.getByRole('button', { name: label });
    if (await btn.isVisible({ timeout: 1500 }).catch(() => false)) {
      await btn.click().catch(() => {});
      await page.waitForTimeout(300);
    }
  }
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }
}

async function loginInBrowser(page: Page, username: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  const userInput = page.locator('input[aria-label="Username"]');
  await userInput.waitFor({ timeout: 15_000 });
  await userInput.focus();
  await page.keyboard.type(username, { delay: 10 });
  const passInput = page.locator('input[aria-label="Password"]');
  await passInput.focus();
  await page.keyboard.type(PW, { delay: 10 });
  await page.getByRole('button', { name: /login/i }).click();

  await page.waitForTimeout(8000);
  await dismissPopups(page);
}

async function createGroupViaUI(
  page: Page,
  groupName: string,
  memberUsername: string,
) {
  const newTrigger = page.getByRole('button', { name: /^new$/i });
  await expect(newTrigger).toBeVisible({ timeout: 8000 });
  await newTrigger.click();
  await page.waitForTimeout(500);

  const newGroupItem = page.getByRole('menuitem', { name: /new group/i });
  await expect(newGroupItem).toBeVisible({ timeout: 5000 });
  await newGroupItem.click();
  await page.waitForTimeout(2000);

  const groupNameInput = page.getByLabel('Group Name');
  await expect(groupNameInput).toBeVisible({ timeout: 5000 });
  await groupNameInput.click();
  await page.keyboard.type(groupName, { delay: 10 });
  await page.waitForTimeout(300);

  const memberTile = page.getByLabel(
    new RegExp(`select contact ${memberUsername}`, 'i'),
  );
  if (await memberTile.isVisible({ timeout: 5000 }).catch(() => false)) {
    await memberTile.click();
  } else {
    await page.locator(`text=${memberUsername}`).first().click({ timeout: 5000 });
  }
  await page.waitForTimeout(400);

  const createBtn = page.getByRole('button', { name: /^create$/i });
  await expect(createBtn).toBeVisible({ timeout: 3000 });
  await createBtn.click();
  // Wait long enough for createGroup → 201 → seedInitialGroupKey →
  // performRotation upload. The seed POSTs to /api/groups/:id/keys and
  // the rotation includes per-member envelope wrapping, which is a few
  // ECDH ops + HTTPS round trips.
  await page.waitForTimeout(6000);
}

async function openGroupByName(page: Page, groupName: string) {
  // After create, the app pops back to home. The group should be at the
  // top of the conversation list. We match on the numeric suffix from
  // the group name (the `ts` portion) rather than the full string —
  // CanvasKit input fields occasionally swallow the leading character
  // typed into them, leaving the rendered group name one char shorter
  // than expected.  Matching the suffix is robust to that.
  const tail = groupName.replace(/^\D+/, '');
  const candidates = [
    page.getByRole('button', {
      name: new RegExp(`conversation: .*${tail}`, 'i'),
    }),
    page.getByRole('button', { name: new RegExp(tail, 'i') }),
    page.locator(`text=${tail}`).first(),
  ];
  for (const loc of candidates) {
    if (await loc.isVisible({ timeout: 4000 }).catch(() => false)) {
      await loc.click();
      await page.waitForTimeout(3000);
      return;
    }
  }
  throw new Error(`Could not find conversation matching /${tail}/`);
}

async function sendMessageInOpenChat(page: Page, content: string) {
  const input = page.getByRole('textbox').last();
  await input.waitFor({ timeout: 10_000 });
  await input.focus();
  await page.waitForTimeout(200);
  await page.keyboard.type(content, { delay: 8 });
  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');
  // Allow the WS roundtrip + render.
  await page.waitForTimeout(4000);
}

async function bodyText(page: Page): Promise<string> {
  return (await page.textContent('body').catch(() => '')) ?? '';
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test.describe('Group encryption — two-party roundtrip on a fresh group', () => {
  let alice: any;
  let bob: any;

  test.beforeAll(async () => {
    console.log(`\nEncryption-roundtrip test (server=${SERVER})`);
    console.log(`  ${ALICE} / ${BOB} / group=${GROUP_NAME}`);

    if (!(await serverIsHealthy())) {
      // Don't gate the maintained suite on a misconfigured server when
      // it's clearly the env that's broken (no /api/health). A
      // green-but-skipped run is more useful than a hard failure that
      // hides the real cause.
      test.skip(true, `${SERVER}/api/health unreachable — skipping`);
      return;
    }

    alice = await registerOrLogin(ALICE);
    bob = await registerOrLogin(BOB);
    expect(alice?.access_token, 'alice login').toBeTruthy();
    expect(bob?.access_token, 'bob login').toBeTruthy();

    await establishContact(alice, bob);
  });

  test('alice creates encrypted group via UI; both decrypt each other', async ({
    browser,
  }) => {
    test.setTimeout(360_000);

    // -----------------------------------------------------------------
    // 0. Open BOTH sessions first and keep them open for the rest of
    //    the test. Bob's client must upload his X3DH bundle BEFORE
    //    Alice creates the group, otherwise Alice's seed produces zero
    //    envelopes for Bob. Re-using the same browser context for
    //    Bob's "bootstrap" and "actual" sessions is essential — each
    //    context generates its own keypair on first login, so a
    //    throwaway bootstrap context would put a different public key
    //    on the server than what Bob's real test session can unwrap
    //    against. (That bites real users too if they reset their
    //    secure storage between sessions, but that's a separate
    //    concern.)
    // -----------------------------------------------------------------
    const bobCtx = await browser.newContext({
      viewport: { width: 1440, height: 900 },
    });
    const bobPage = await bobCtx.newPage();
    const bobCryptoLog: string[] = [];
    bobPage.on('console', (m) => {
      const text = m.text();
      if (/GroupCrypto|Crypto|GroupEnvelopeUnwrap|MAC|seedInitial/i.test(text)) {
        bobCryptoLog.push(text);
        console.log(`  [bob] ${text}`);
      }
    });
    await loginInBrowser(bobPage, BOB);
    // Give uploadKeys time to land before Alice's seed fetches Bob's
    // identity bundle. The "[Crypto] Keys uploaded to server" log line
    // is the signal we want; a fixed delay is good enough.
    await bobPage.waitForTimeout(6000);

    // -----------------------------------------------------------------
    // 1. Alice opens the app, drives the New Group flow (which is what
    //    triggers seedInitialGroupKey on the client). Anything that
    //    creates the group via the REST API directly would bypass the
    //    fix and isn't the regression we're guarding against.
    // -----------------------------------------------------------------
    const aliceCtx = await browser.newContext({
      viewport: { width: 1440, height: 900 },
    });
    const alicePage = await aliceCtx.newPage();
    const aliceCryptoLog: string[] = [];
    alicePage.on('console', (m) => {
      const text = m.text();
      if (/GroupCrypto|Crypto|GroupEnvelopeUnwrap|MAC|seedInitial/i.test(text)) {
        aliceCryptoLog.push(text);
        console.log(`  [alice] ${text}`);
      }
    });

    await loginInBrowser(alicePage, ALICE);
    await alicePage.screenshot({ path: `${SS}/01-alice-home.png`, fullPage: true });

    await createGroupViaUI(alicePage, GROUP_NAME, BOB);
    await alicePage.screenshot({
      path: `${SS}/02-after-create.png`,
      fullPage: true,
    });

    await openGroupByName(alicePage, GROUP_NAME);
    await alicePage.screenshot({
      path: `${SS}/03-alice-group-open.png`,
      fullPage: true,
    });

    // -----------------------------------------------------------------
    // 2. Alice sends a message and asserts SHE can read it. Pre-fix,
    //    the sender's own conversation preview showed the raw GRP1:...
    //    ciphertext because the seed sealed the envelope under a stale
    //    self-identity that her current private key couldn't unwrap.
    // -----------------------------------------------------------------
    const aliceMsg = `alice-says-hello-${ts}`;
    await sendMessageInOpenChat(alicePage, aliceMsg);
    await alicePage.screenshot({
      path: `${SS}/04-alice-sent.png`,
      fullPage: true,
    });

    const aliceBody = await bodyText(alicePage);
    // Match on the suffix — CanvasKit may swallow the first typed char.
    expect(
      aliceBody.includes(`says-hello-${ts}`),
      'Alice (sender) sees her own message as plaintext',
    ).toBe(true);
    expect(
      aliceBody.includes('GRP1:') || aliceBody.includes('GRP2:'),
      "No raw ciphertext leaking into Alice's UI",
    ).toBe(false);
    expect(
      /could not be decrypted/i.test(aliceBody),
      'No undecryptable-placeholder on the sender side',
    ).toBe(false);

    // No envelope-unwrap exceptions should have shown up in the
    // console during a healthy roundtrip. If they did, the seed wrote
    // bad envelopes again.
    const unwrapErrors = aliceCryptoLog.filter((l) =>
      l.includes('GroupEnvelopeUnwrapException'),
    );
    expect(
      unwrapErrors,
      `No GroupEnvelopeUnwrapException on Alice — got ${unwrapErrors.length}`,
    ).toEqual([]);

    // -----------------------------------------------------------------
    // 3. Bob's session is already open from step 0. Open the group —
    //    his client will fetch the latest envelope (with the correct
    //    pubkey wrapping) and decrypt Alice's message.
    // -----------------------------------------------------------------
    await openGroupByName(bobPage, GROUP_NAME);
    await bobPage.screenshot({
      path: `${SS}/05-bob-receives.png`,
      fullPage: true,
    });

    const bobBody = await bodyText(bobPage);
    expect(
      bobBody.includes(`says-hello-${ts}`),
      "Bob (recipient) decrypts Alice's message",
    ).toBe(true);
    expect(
      /could not be decrypted/i.test(bobBody),
      'No undecryptable-placeholder on the recipient side',
    ).toBe(false);

    const bobUnwrapErrors = bobCryptoLog.filter((l) =>
      l.includes('GroupEnvelopeUnwrapException'),
    );
    expect(
      bobUnwrapErrors,
      `No GroupEnvelopeUnwrapException on Bob — got ${bobUnwrapErrors.length}`,
    ).toEqual([]);

    // -----------------------------------------------------------------
    // 4. Bob replies; Alice must decrypt the reply. Reverses the
    //    direction of #3 to catch one-sided wrapping bugs.
    // -----------------------------------------------------------------
    const bobMsg = `bob-replies-${ts}`;
    await sendMessageInOpenChat(bobPage, bobMsg);
    await bobPage.screenshot({
      path: `${SS}/06-bob-sent.png`,
      fullPage: true,
    });

    await alicePage.waitForTimeout(4000);
    await alicePage.screenshot({
      path: `${SS}/07-alice-after-bob-reply.png`,
      fullPage: true,
    });
    const aliceBodyAfter = await bodyText(alicePage);
    expect(
      aliceBodyAfter.includes(`replies-${ts}`),
      "Alice decrypts Bob's reply",
    ).toBe(true);

    await aliceCtx.close();
    await bobCtx.close();
  });
});
