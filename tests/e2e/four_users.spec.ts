import { test, Page, BrowserContext } from '@playwright/test';

const APP = 'http://localhost:8081';
const SERVER = 'http://localhost:8080';
const SS = 'tests/e2e/test-results/four-users';

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function fillAndSubmit(page: Page, username: string, password: string) {
  const vp = page.viewportSize()!;
  await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
  await page.waitForTimeout(200);
  await page.keyboard.type(username, { delay: 20 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 20 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(4000);
}

async function goToApp(page: Page) {
  await page.goto(APP);
  await page.waitForTimeout(4000);
}

async function register(page: Page, username: string, password: string) {
  await goToApp(page);
  // Click "Create an account"
  const vp = page.viewportSize()!;
  await page.mouse.click(vp.width / 2, vp.height / 2 + 120);
  await page.waitForTimeout(2000);
  // Fill register form (username, password, confirm password)
  await page.mouse.click(vp.width / 2, vp.height / 2 - 80);
  await page.waitForTimeout(200);
  await page.keyboard.type(username, { delay: 20 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 20 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 20 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(5000);
}

async function login(page: Page, username: string, password: string) {
  await goToApp(page);
  await fillAndSubmit(page, username, password);
}

async function sendMsg(page: Page, text: string) {
  await page.mouse.click(180, 710);
  await page.waitForTimeout(200);
  await page.keyboard.type(text, { delay: 10 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);
}

test.describe('4-User Live Test', () => {
  test.setTimeout(600000); // 10 minutes

  test('register, add contacts, create group, chat', async ({ browser }) => {
    // Create 4 browser windows side by side
    const mkCtx = () => browser.newContext({ viewport: { width: 400, height: 700 } });
    const [ctx1, ctx2, ctx3, ctx4] = await Promise.all([mkCtx(), mkCtx(), mkCtx(), mkCtx()]);
    const [p1, p2, p3, p4] = await Promise.all([
      ctx1.newPage(), ctx2.newPage(), ctx3.newPage(), ctx4.newPage(),
    ]);
    const pages = { alpha: p1, bravo: p2, charlie: p3, delta: p4 };
    const users = ['alpha', 'bravo', 'charlie', 'delta'] as const;

    // ============================================================
    // PHASE 1: Register all 4 users via API (faster than UI)
    // ============================================================
    console.log('--- Phase 1: Registering users ---');
    const tokens: Record<string, string> = {};
    const userIds: Record<string, string> = {};

    for (const u of users) {
      const res = await fetch(`${SERVER}/api/auth/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u, password: 'pass1234' }),
      }).then(r => r.json()).catch(() => null);

      if (res?.access_token) {
        tokens[u] = res.access_token;
        userIds[u] = res.user_id;
      } else {
        const login = await fetch(`${SERVER}/api/auth/login`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: u, password: 'pass1234' }),
        }).then(r => r.json());
        tokens[u] = login.access_token;
        userIds[u] = login.user_id;
      }
    }
    console.log('All 4 users registered');

    // Make all contacts
    for (let i = 0; i < users.length; i++) {
      for (let j = i + 1; j < users.length; j++) {
        try {
          const c = await fetch(`${SERVER}/api/contacts/request`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${tokens[users[i]]}` },
            body: JSON.stringify({ username: users[j] }),
          }).then(r => r.json());
          if (c.contact_id) {
            await fetch(`${SERVER}/api/contacts/accept`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${tokens[users[j]]}` },
              body: JSON.stringify({ contact_id: c.contact_id }),
            });
          }
        } catch (_) {}
      }
    }
    console.log('All contacts established');

    // ============================================================
    // PHASE 2: Login all 4 users in the app
    // ============================================================
    console.log('--- Phase 2: Logging in ---');
    await Promise.all(users.map(u => login(pages[u], u, 'pass1234')));
    await Promise.all(users.map(u => ss(pages[u], `01-${u}-home`)));
    console.log('All 4 logged in');

    // ============================================================
    // PHASE 3: 1:1 chats - alpha messages bravo
    // ============================================================
    console.log('--- Phase 3: 1:1 chat ---');

    // Alpha clicks on bravo's conversation (or first contact)
    await pages.alpha.mouse.click(200, 85);
    await pages.alpha.waitForTimeout(3000);
    await ss(pages.alpha, '02-alpha-opened-chat');

    await sendMsg(pages.alpha, 'Hey bravo! Can you hear me?');
    await ss(pages.alpha, '03-alpha-sent');

    // Bravo refreshes and opens
    await pages.bravo.mouse.click(390, 28); // three dots
    await pages.bravo.waitForTimeout(500);
    await pages.bravo.mouse.click(350, 70); // refresh
    await pages.bravo.waitForTimeout(2000);
    await pages.bravo.mouse.click(200, 85);
    await pages.bravo.waitForTimeout(3000);
    await ss(pages.bravo, '04-bravo-sees-message');

    await sendMsg(pages.bravo, 'Loud and clear alpha! 🔥');
    await pages.alpha.waitForTimeout(2000);
    await ss(pages.alpha, '05-alpha-sees-reply');

    // ============================================================
    // PHASE 4: Create a group with all 4 users
    // ============================================================
    console.log('--- Phase 4: Group creation ---');

    // Alpha goes back to conversations
    await pages.alpha.mouse.click(25, 28);
    await pages.alpha.waitForTimeout(1500);

    // Create group via API (UI group creation is complex to automate)
    const groupRes = await fetch(`${SERVER}/api/groups`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${tokens.alpha}` },
      body: JSON.stringify({
        name: 'Echo Squad',
        member_ids: [userIds.bravo, userIds.charlie, userIds.delta],
      }),
    }).then(r => r.json());
    console.log('Group created:', groupRes);

    // Refresh all pages to see the group
    for (const u of users) {
      await pages[u].mouse.click(390, 28);
      await pages[u].waitForTimeout(500);
      await pages[u].mouse.click(350, 70);
      await pages[u].waitForTimeout(2000);
    }
    await Promise.all(users.map(u => ss(pages[u], `06-${u}-sees-group`)));

    // ============================================================
    // PHASE 5: Group chat - everyone sends messages
    // ============================================================
    console.log('--- Phase 5: Group messaging ---');

    // Alpha opens the group (should be second item in list, or first if no 1:1)
    // Click on "Echo Squad" - might be at position 85 or 130 depending on list
    await pages.alpha.mouse.click(200, 130);
    await pages.alpha.waitForTimeout(3000);
    await ss(pages.alpha, '07-alpha-group-chat');

    await sendMsg(pages.alpha, 'Welcome to Echo Squad everyone! 🎉');
    await ss(pages.alpha, '08-alpha-group-sent');

    // Bravo opens group and sends
    await pages.bravo.mouse.click(25, 28); // back first
    await pages.bravo.waitForTimeout(1000);
    await pages.bravo.mouse.click(200, 130);
    await pages.bravo.waitForTimeout(3000);
    await sendMsg(pages.bravo, 'Hey squad! Bravo checking in 🫡');
    await ss(pages.bravo, '09-bravo-group-sent');

    // Charlie opens group and sends
    await pages.charlie.mouse.click(200, 85);
    await pages.charlie.waitForTimeout(3000);
    await sendMsg(pages.charlie, 'Charlie here! Testing group chat 💬');
    await ss(pages.charlie, '10-charlie-group-sent');

    // Delta opens group and sends
    await pages.delta.mouse.click(200, 85);
    await pages.delta.waitForTimeout(3000);
    await sendMsg(pages.delta, 'Delta reporting! All systems go 🚀');
    await ss(pages.delta, '11-delta-group-sent');

    // Wait for all messages to propagate
    await pages.alpha.waitForTimeout(3000);
    await ss(pages.alpha, '12-alpha-sees-all-group-msgs');

    // ============================================================
    // PHASE 6: Test different content types
    // ============================================================
    console.log('--- Phase 6: Content types ---');

    // URLs
    await sendMsg(pages.alpha, 'Check this out: https://github.com/NC1107/echo-messenger');
    await ss(pages.alpha, '13-url-in-group');

    // Emoji storm
    await sendMsg(pages.bravo, '🎮🎵🎨📱💻🔒🌍⚡️🏆❤️');
    await ss(pages.bravo, '14-emoji-storm');

    // Code/markdown
    await sendMsg(pages.charlie, '```rust\nfn main() { println!("Hello from Echo!"); }\n```');
    await ss(pages.charlie, '15-code-block');

    // HTML/XSS attempt
    await sendMsg(pages.delta, '<img src=x onerror=alert(1)> <b>bold</b> <a href="evil.com">click me</a>');
    await ss(pages.delta, '16-html-attempt');

    // Unicode and special chars
    await sendMsg(pages.alpha, '日本語テスト العربية Ελληνικά 🇺🇸🇯🇵🇩🇪');
    await ss(pages.alpha, '17-unicode');

    // Very long message
    await sendMsg(pages.bravo, 'Lorem ipsum '.repeat(30));
    await ss(pages.bravo, '18-long-message');

    // Empty-ish messages
    await sendMsg(pages.charlie, '.');
    await sendMsg(pages.charlie, ' ');
    await ss(pages.charlie, '19-tiny-messages');

    // ============================================================
    // PHASE 7: Rapid conversation in group
    // ============================================================
    console.log('--- Phase 7: Rapid exchange ---');

    const rapidMsgs = [
      { user: 'alpha', msg: 'Alpha: 1' },
      { user: 'bravo', msg: 'Bravo: 2' },
      { user: 'charlie', msg: 'Charlie: 3' },
      { user: 'delta', msg: 'Delta: 4' },
      { user: 'alpha', msg: 'Alpha: 5' },
      { user: 'bravo', msg: 'Bravo: 6' },
    ];

    for (const { user, msg } of rapidMsgs) {
      await sendMsg(pages[user as keyof typeof pages], msg);
    }

    await pages.alpha.waitForTimeout(3000);
    await Promise.all(users.map(u => ss(pages[u], `20-${u}-rapid-exchange`)));

    // ============================================================
    // PHASE 8: Back to conversations - check state
    // ============================================================
    console.log('--- Phase 8: Final state ---');

    for (const u of users) {
      await pages[u].mouse.click(25, 28);
      await pages[u].waitForTimeout(1500);
    }
    await Promise.all(users.map(u => ss(pages[u], `21-${u}-final-conversations`)));

    console.log('=== TEST COMPLETE ===');

    // Cleanup
    await Promise.all([ctx1.close(), ctx2.close(), ctx3.close(), ctx4.close()]);
  });
});
