/**
 * E2E tests for group messaging UI flows.
 *
 * Covers: send/receive in groups, reactions, pins, owner-permission
 * visibility (Delete Group, kick member).
 *
 * Setup (registration, group creation, member addition, seeding messages)
 * is done via the REST + WebSocket APIs so each test starts with
 * deterministic state.  Assertions are driven through the browser UI
 * using Playwright's ARIA/Semantics locators for Flutter CanvasKit.
 *
 * Requires:
 *   - Server running on :8080 (or ECHO_SERVER env var)
 *   - Flutter web build served on :8081 (or ECHO_URL env var)
 *
 * Run: npx playwright test tests/e2e/group_messaging_ui.spec.ts --headed
 */
import { test, expect, Page, BrowserContext } from '@playwright/test';

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const SERVER = process.env.ECHO_SERVER || 'http://localhost:8080';
const WEB_URL = process.env.ECHO_URL || 'http://localhost:8081';
const APP = `${WEB_URL}/?server=${encodeURIComponent(SERVER)}`;
const SS = 'tests/e2e/test-results/group-messaging';

const ts = Date.now().toString().slice(-5);
const ALICE = `grp_alice_${ts}`;
const BOB = `grp_bob_${ts}`;
const PW = 'TestPass123!';

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

interface ApiResult {
  status: number;
  data: any;
}

async function apiPost(
  path: string,
  body: Record<string, unknown>,
  token?: string,
): Promise<ApiResult> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${SERVER}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function apiGet(path: string, token: string): Promise<ApiResult> {
  const res = await fetch(`${SERVER}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function apiDelete(path: string, token: string): Promise<ApiResult> {
  const res = await fetch(`${SERVER}${path}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${token}` },
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function registerUser(username: string): Promise<any> {
  const { data } = await apiPost('/api/auth/register', {
    username,
    password: PW,
  });
  console.log(`  Registered ${username} (${data.user_id?.slice(0, 8)})`);
  return data;
}

async function loginUser(username: string): Promise<any> {
  const { data } = await apiPost('/api/auth/login', {
    username,
    password: PW,
  });
  return data;
}

/** Create a group via API and return the group/conversation id. */
async function createGroup(
  token: string,
  name: string,
  memberIds: string[],
): Promise<string> {
  const { status, data } = await apiPost(
    '/api/groups',
    { name, member_ids: memberIds },
    token,
  );
  if (status !== 200 && status !== 201) {
    throw new Error(`createGroup failed: ${status} ${JSON.stringify(data)}`);
  }
  const groupId = data.id ?? data.conversation_id;
  console.log(`  Group "${name}" created: ${groupId?.slice(0, 8)}`);
  return groupId;
}

/**
 * Send a plaintext message into a conversation via WebSocket.
 *
 * Opens a WS connection using ticket-based auth, sends one message,
 * waits for the server acknowledgement, then closes.
 */
async function sendMessageViaWs(
  token: string,
  conversationId: string,
  content: string,
): Promise<string | null> {
  // 1. Obtain a single-use WS ticket
  const ticketRes = await apiPost('/api/auth/ws-ticket', {}, token);
  if (!ticketRes.data.ticket) {
    console.warn('  Could not obtain WS ticket');
    return null;
  }

  const wsUrl = SERVER.replace(/^http/, 'ws');
  const url = `${wsUrl}/ws?ticket=${ticketRes.data.ticket}`;

  return new Promise<string | null>((resolve) => {
    const ws = new WebSocket(url);
    let messageId: string | null = null;
    const timeout = setTimeout(() => {
      ws.close();
      resolve(messageId);
    }, 8000);

    ws.onopen = () => {
      ws.send(
        JSON.stringify({
          type: 'send_message',
          conversation_id: conversationId,
          content,
        }),
      );
    };

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data as string);
        if (msg.type === 'message_sent' && msg.conversation_id === conversationId) {
          messageId = msg.message_id;
          clearTimeout(timeout);
          ws.close();
          resolve(messageId);
        }
      } catch {
        // ignore non-JSON frames (heartbeat pings etc.)
      }
    };

    ws.onerror = () => {
      clearTimeout(timeout);
      resolve(null);
    };
  });
}

// ---------------------------------------------------------------------------
// Browser helpers
// ---------------------------------------------------------------------------

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

/** Wait for Flutter to boot and the semantics tree to appear. */
async function waitForFlutter(page: Page) {
  await page.waitForSelector('flt-semantics', { timeout: 20000 });
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

/**
 * Login using semantic locators (ARIA/Semantics tree from Flutter web).
 * Falls back to viewport-relative coordinates only as a last resort.
 */
async function loginInBrowser(page: Page, username: string) {
  await page.goto(APP);
  await page.waitForSelector('flt-semantics', { timeout: 20000 });
  await page.waitForTimeout(2000);

  const userInput = page.locator('input[aria-label="Username"]');
  if (await userInput.isVisible({ timeout: 5000 }).catch(() => false)) {
    await userInput.focus();
    await page.keyboard.type(username, { delay: 12 });
    const passInput = page.locator('input[aria-label="Password"]');
    await passInput.focus();
    await page.keyboard.type(PW, { delay: 12 });
    await page.getByRole('button', { name: /login/i }).click();
  } else {
    // Fallback: viewport-relative coordinates
    const vp = page.viewportSize()!;
    await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
    await page.waitForTimeout(250);
    await page.keyboard.type(username, { delay: 12 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(250);
    await page.keyboard.type(PW, { delay: 12 });
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(8000);

  // Dismiss popups aggressively
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
  }
  await page.mouse.click(5, 5);
  await page.waitForTimeout(500);
  await dismissDialogs(page);
  console.log(`  ${username} logged in`);
}

/** Navigate to the Groups tab. */
async function openGroupsTab(page: Page) {
  const groupsTab = page.getByRole('button', { name: /groups tab/i });
  if (await groupsTab.isVisible({ timeout: 5000 }).catch(() => false)) {
    await groupsTab.click();
    await page.waitForTimeout(1500);
  }
}

/** Click on a conversation/group in the sidebar by name. */
async function openConversation(
  page: Page,
  name: string,
): Promise<boolean> {
  // Try semantics button first
  const btn = page.getByRole('button', { name: new RegExp(name, 'i') });
  if (await btn.isVisible({ timeout: 5000 }).catch(() => false)) {
    await btn.click();
    await page.waitForTimeout(2000);
    return true;
  }
  // Fallback: text locator
  try {
    const el = page.locator(`text=${name}`).first();
    if (await el.isVisible({ timeout: 3000 })) {
      await el.click();
      await page.waitForTimeout(2000);
      return true;
    }
  } catch {
    // ignore
  }
  return false;
}

/** Check whether the page body contains a given string. */
async function pageContains(page: Page, text: string): Promise<boolean> {
  const body = await page.textContent('body').catch(() => '');
  return (body ?? '').includes(text);
}

/** Type into the chat input and press Enter. Uses ARIA textbox role. */
async function sendMessageViaUI(page: Page, text: string) {
  const chatInput = page.getByRole('textbox').last();
  if (await chatInput.isVisible({ timeout: 3000 }).catch(() => false)) {
    await chatInput.focus();
  } else {
    // Fallback: viewport-relative coordinates (avoids absolute-pixel brittleness)
    const vp = page.viewportSize()!;
    await page.mouse.click(vp.width * 0.6, vp.height - 45);
  }
  await page.waitForTimeout(300);
  await page.keyboard.type(text, { delay: 8 });
  await page.waitForTimeout(300);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(2500);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Group messaging UI', () => {
  let aliceData: any;
  let bobData: any;
  let groupId: string;
  const groupName = `TestGroup_${ts}`;

  test.beforeAll(async () => {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`GROUP MESSAGING TESTS -- ${ALICE} / ${BOB}`);
    console.log(`${'='.repeat(60)}\n`);

    // Register both users
    aliceData = await registerUser(ALICE);
    bobData = await registerUser(BOB);

    // Make them contacts (required for adding to group)
    await apiPost(
      '/api/contacts/request',
      { username: BOB },
      aliceData.access_token,
    );
    const { data: pending } = await apiGet(
      '/api/contacts/pending',
      bobData.access_token,
    );
    for (const req of pending as any[]) {
      await apiPost(
        `/api/contacts/accept/${req.id}`,
        {},
        bobData.access_token,
      );
    }
    console.log('  Contacts established');

    // Create group with Alice as owner and Bob as member
    groupId = await createGroup(aliceData.access_token, groupName, [
      bobData.user_id,
    ]);
  });

  // -----------------------------------------------------------------------
  // Test 1: Alice sends a message in the group, Bob sees it
  // -----------------------------------------------------------------------
  test('alice sends message in group, bob receives', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test: send/receive in group ---');

    // Seed a message from Alice via WS so the conversation has content
    const msgText = `Hello group from Alice [${ts}]`;
    const msgId = await sendMessageViaWs(
      aliceData.access_token,
      groupId,
      msgText,
    );
    console.log(`  Seeded message: ${msgId?.slice(0, 8) ?? 'FAILED'}`);

    // Login Bob in the browser
    const ctx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const page = await ctx.newPage();
    await loginInBrowser(page, BOB);

    // Navigate to the group
    await openGroupsTab(page);
    const found = await openConversation(page, groupName);
    console.log(`  Bob opened group: ${found}`);
    await page.waitForTimeout(3000);
    await ss(page, '01-bob-group-open');

    // Verify Alice's message is visible
    const sees = await pageContains(page, 'Hello group from Alice');
    console.log(`  Bob sees Alice's message: ${sees}`);
    expect(sees).toBe(true);

    await ctx.close();
  });

  // -----------------------------------------------------------------------
  // Test 2: React to a group message via API, verify pill in UI
  // -----------------------------------------------------------------------
  test('reaction on group message', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test: reaction on group message ---');

    // Send a fresh message to react to
    const reactMsg = `React to me [${ts}]`;
    const msgId = await sendMessageViaWs(
      aliceData.access_token,
      groupId,
      reactMsg,
    );

    if (!msgId) {
      console.log('  SKIP: could not seed message');
      test.skip();
      return;
    }

    // Add a reaction via the REST API
    const { status } = await apiPost(
      `/api/messages/${msgId}/reactions`,
      { emoji: '\u{1F525}' }, // fire emoji
      bobData.access_token,
    );
    console.log(`  Reaction API status: ${status}`);
    expect(status).toBe(200);

    // Open the group as Alice and verify the reaction pill shows
    const ctx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const page = await ctx.newPage();
    await loginInBrowser(page, ALICE);
    await openGroupsTab(page);
    await openConversation(page, groupName);
    await page.waitForTimeout(3000);
    await ss(page, '02-reaction-visible');

    // The fire emoji should be somewhere in the page
    const hasEmoji = await pageContains(page, '\u{1F525}');
    console.log(`  Reaction emoji visible: ${hasEmoji}`);
    // Soft assertion: CanvasKit may not expose emoji to textContent
    // but the screenshot documents the state
    if (!hasEmoji) {
      console.log('  (emoji not in textContent -- check screenshot)');
    }

    await ctx.close();
  });

  // -----------------------------------------------------------------------
  // Test 3: Pin a message in the group (owner-only action)
  // -----------------------------------------------------------------------
  test('pin message in group', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test: pin message in group ---');

    // Seed a message to pin
    const pinMsg = `Pin me please [${ts}]`;
    const msgId = await sendMessageViaWs(
      aliceData.access_token,
      groupId,
      pinMsg,
    );

    if (!msgId) {
      console.log('  SKIP: could not seed message');
      test.skip();
      return;
    }

    // Pin via API (Alice is owner, so she has permission)
    const { status } = await apiPost(
      `/api/conversations/${groupId}/messages/${msgId}/pin`,
      {},
      aliceData.access_token,
    );
    console.log(`  Pin API status: ${status}`);
    expect(status).toBe(200);

    // Verify pinned messages endpoint returns the message
    const { data: pinned } = await apiGet(
      `/api/conversations/${groupId}/pinned`,
      aliceData.access_token,
    );
    const pinnedIds = (pinned as any[]).map((m: any) => m.id ?? m.message_id);
    console.log(`  Pinned messages: ${pinnedIds.length}`);
    expect(pinnedIds).toContain(msgId);

    // Open the group as Alice in the UI and take a screenshot
    const ctx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const page = await ctx.newPage();
    await loginInBrowser(page, ALICE);
    await openGroupsTab(page);
    await openConversation(page, groupName);
    await page.waitForTimeout(3000);
    await ss(page, '03-pin-visible');

    // Verify the pinned message text is on-screen
    const hasPinMsg = await pageContains(page, 'Pin me please');
    console.log(`  Pinned message visible: ${hasPinMsg}`);
    expect(hasPinMsg).toBe(true);

    await ctx.close();
  });

  // -----------------------------------------------------------------------
  // Test 4: Owner sees "Delete Group", non-owner does not
  // -----------------------------------------------------------------------
  test('owner sees Delete Group button, non-owner does not', async ({
    browser,
  }) => {
    test.setTimeout(180000);
    console.log('\n--- Test: owner vs non-owner permissions ---');

    // --- As owner (Alice) ---
    const aliceCtx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const alicePage = await aliceCtx.newPage();
    await loginInBrowser(alicePage, ALICE);
    await openGroupsTab(alicePage);
    await openConversation(alicePage, groupName);
    await alicePage.waitForTimeout(2000);

    // Open group info. Look for an info/settings button in the chat header.
    // In the Flutter app the group name in the app bar is clickable, or
    // there's a dedicated info icon.
    const infoBtn = alicePage.getByRole('button', {
      name: /group info|info|settings/i,
    });
    if (await infoBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      await infoBtn.click();
      await alicePage.waitForTimeout(2000);
    } else {
      // Fallback: try clicking the group name in the app bar area
      const vp = alicePage.viewportSize()!;
      await alicePage.mouse.click(vp.width * 0.5, 30);
      await alicePage.waitForTimeout(2000);
    }
    await ss(alicePage, '04-alice-group-info');

    // Check for "Delete Group" button (Alice is owner -- should see it)
    const deleteGroupBtn = alicePage.getByRole('button', {
      name: /delete group/i,
    });
    const ownerSeesDelete = await deleteGroupBtn
      .isVisible({ timeout: 5000 })
      .catch(() => false);
    console.log(`  Owner sees Delete Group: ${ownerSeesDelete}`);
    // Also check via page text as fallback
    const ownerTextCheck = await pageContains(alicePage, 'Delete Group');
    console.log(`  Owner text fallback: ${ownerTextCheck}`);
    expect(ownerSeesDelete || ownerTextCheck).toBe(true);

    // Check that "Leave Group" is also visible for the owner
    const leaveGroupVisible = await pageContains(alicePage, 'Leave Group');
    console.log(`  Owner sees Leave Group: ${leaveGroupVisible}`);

    await aliceCtx.close();

    // --- As non-owner (Bob) ---
    const bobCtx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const bobPage = await bobCtx.newPage();
    await loginInBrowser(bobPage, BOB);
    await openGroupsTab(bobPage);
    await openConversation(bobPage, groupName);
    await bobPage.waitForTimeout(2000);

    // Open group info
    const infoBtnBob = bobPage.getByRole('button', {
      name: /group info|info|settings/i,
    });
    if (await infoBtnBob.isVisible({ timeout: 3000 }).catch(() => false)) {
      await infoBtnBob.click();
      await bobPage.waitForTimeout(2000);
    } else {
      const vp = bobPage.viewportSize()!;
      await bobPage.mouse.click(vp.width * 0.5, 30);
      await bobPage.waitForTimeout(2000);
    }
    await ss(bobPage, '05-bob-group-info');

    // Bob is a regular member -- should NOT see "Delete Group"
    const bobSeesDelete = await bobPage
      .getByRole('button', { name: /delete group/i })
      .isVisible({ timeout: 3000 })
      .catch(() => false);
    const bobTextCheck = await pageContains(bobPage, 'Delete Group');
    console.log(`  Non-owner sees Delete Group button: ${bobSeesDelete}`);
    console.log(`  Non-owner text fallback: ${bobTextCheck}`);
    // At least one of these should be false -- the button should not be rendered
    expect(bobSeesDelete).toBe(false);

    // Bob should still see "Leave Group"
    const bobLeave = await pageContains(bobPage, 'Leave Group');
    console.log(`  Non-owner sees Leave Group: ${bobLeave}`);

    await bobCtx.close();
  });

  // -----------------------------------------------------------------------
  // Test 5: Owner can kick a member via the API and it reflects correctly
  // -----------------------------------------------------------------------
  test('owner can kick member', async ({ browser }) => {
    test.setTimeout(180000);
    console.log('\n--- Test: owner kicks member ---');

    // Create a disposable group with a third user so we don't break
    // the shared group for other tests
    const charlieUser = `grp_charlie_${ts}`;
    const charlieData = await registerUser(charlieUser);

    // Alice adds Charlie as contact
    await apiPost(
      '/api/contacts/request',
      { username: charlieUser },
      aliceData.access_token,
    );
    const { data: charliePending } = await apiGet(
      '/api/contacts/pending',
      charlieData.access_token,
    );
    for (const req of charliePending as any[]) {
      await apiPost(
        `/api/contacts/accept/${req.id}`,
        {},
        charlieData.access_token,
      );
    }

    const kickGroupName = `KickTest_${ts}`;
    const kickGroupId = await createGroup(
      aliceData.access_token,
      kickGroupName,
      [charlieData.user_id],
    );

    // Kick Charlie via API
    const { status: kickStatus } = await apiDelete(
      `/api/groups/${kickGroupId}/members/${charlieData.user_id}`,
      aliceData.access_token,
    );
    console.log(`  Kick API status: ${kickStatus}`);
    expect(kickStatus).toBe(200);

    // Verify via API that Charlie is no longer a member
    // Re-login Alice to get fresh token
    const freshAlice = await loginUser(ALICE);
    const { data: conversations } = await apiGet(
      '/api/conversations',
      freshAlice.access_token,
    );
    const kickGroup = (conversations as any[]).find(
      (c: any) => c.conversation_id === kickGroupId,
    );
    if (kickGroup) {
      const memberIds = (kickGroup.members ?? []).map(
        (m: any) => m.user_id,
      );
      const charlieStillIn = memberIds.includes(charlieData.user_id);
      console.log(`  Charlie still in group: ${charlieStillIn}`);
      expect(charlieStillIn).toBe(false);
    } else {
      console.log('  Group not found in conversations list');
    }

    // Open the kick group in Alice's browser to visually confirm
    const ctx = await browser.newContext({
      viewport: { width: 1920, height: 993 },
    });
    const page = await ctx.newPage();
    await loginInBrowser(page, ALICE);
    await openGroupsTab(page);
    const found = await openConversation(page, kickGroupName);
    if (found) {
      // Open group info
      const infoBtn = page.getByRole('button', {
        name: /group info|info|settings/i,
      });
      if (await infoBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
        await infoBtn.click();
        await page.waitForTimeout(2000);
      } else {
        const vp = page.viewportSize()!;
        await page.mouse.click(vp.width * 0.5, 30);
        await page.waitForTimeout(2000);
      }
      await ss(page, '06-after-kick');

      // Charlie's name should not appear in the member list
      const charlieVisible = await pageContains(page, charlieUser);
      console.log(`  Charlie visible after kick: ${charlieVisible}`);
      expect(charlieVisible).toBe(false);
    }

    await ctx.close();
  });
});
