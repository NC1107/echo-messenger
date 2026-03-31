import { test, Page } from '@playwright/test';

const APP = 'http://localhost:8081';
const SS = 'tests/e2e/test-results/beta';

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

async function sendMsg(page: Page, text: string) {
  await page.mouse.click(180, 710);
  await page.waitForTimeout(200);
  await page.keyboard.type(text, { delay: 10 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1500);
}

test.describe('Beta Test Suite', () => {
  test.setTimeout(300000); // 5 minutes

  test('1:1 messaging, special characters, reactions, groups', async ({ browser }) => {
    const aliceCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const bobCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const charlieCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const a = await aliceCtx.newPage();
    const b = await bobCtx.newPage();
    const c = await charlieCtx.newPage();

    // Login all 3
    await login(a, 'alice', 'password123');
    await login(b, 'bob', 'password123');
    await login(c, 'charlie', 'password123');
    await ss(a, '01-alice-home');
    await ss(b, '02-bob-home');

    // === 1:1 Chat ===
    // Alice opens contacts, clicks bob
    await a.mouse.click(360, 28); // contacts icon
    await a.waitForTimeout(2000);
    await ss(a, '03-alice-contacts-or-menu');

    // Navigate back and click conversation if exists, or start from contacts
    await a.goto(APP);
    await a.waitForTimeout(4000);
    await login(a, 'alice', 'password123');

    // Alice starts chat by clicking bob in contacts
    await a.mouse.click(358, 28); // contacts
    await a.waitForTimeout(2000);
    // Click first contact
    await a.mouse.click(210, 100);
    await a.waitForTimeout(3000);
    await ss(a, '04-alice-chat-opened');

    // Send basic messages
    await sendMsg(a, 'Hello Bob!');
    await ss(a, '05-basic-message');

    // Special characters
    await sendMsg(a, '🎉🔥💀 Emoji test!');
    await ss(a, '06-emoji-message');

    await sendMsg(a, '<script>alert("xss")</script>');
    await ss(a, '07-xss-attempt');

    await sendMsg(a, 'Special chars: &amp; < > " \' © ® ™ € £ ¥');
    await ss(a, '08-special-chars');

    // Long message
    await sendMsg(a, 'This is a very long message that tests how the app handles lengthy content. '.repeat(5));
    await ss(a, '09-long-message');

    // URL
    await sendMsg(a, 'Check out https://github.com/NC1107/echo-messenger');
    await ss(a, '10-url-message');

    // Single character
    await sendMsg(a, 'x');
    await ss(a, '11-single-char');

    // Bob checks received messages
    await b.mouse.click(210, 85);
    await b.waitForTimeout(3000);
    await ss(b, '12-bob-sees-all-messages');

    // Bob replies
    await sendMsg(b, 'Got all your messages! Emoji: 😊');
    await b.waitForTimeout(1000);
    await ss(b, '13-bob-replied');

    // Alice sees reply
    await a.waitForTimeout(2000);
    await ss(a, '14-alice-sees-reply');

    // === Rapid fire ===
    for (let i = 1; i <= 10; i++) {
      await a.mouse.click(180, 710);
      await a.waitForTimeout(100);
      await a.keyboard.type(`Rapid msg ${i}`);
      await a.keyboard.press('Enter');
      await a.waitForTimeout(200);
    }
    await a.waitForTimeout(2000);
    await ss(a, '15-rapid-fire-alice');
    await b.waitForTimeout(2000);
    await ss(b, '16-rapid-fire-bob');

    // === Try reactions (long-press) ===
    // Long press on a message bubble (approximate y position of first message)
    await a.mouse.click(100, 200, { button: 'right' }); // try right click
    await a.waitForTimeout(1000);
    await ss(a, '17-reaction-attempt-rightclick');

    // Try actual long press
    await a.mouse.move(100, 200);
    await a.mouse.down();
    await a.waitForTimeout(1000);
    await a.mouse.up();
    await a.waitForTimeout(1000);
    await ss(a, '18-reaction-attempt-longpress');

    // === Back to conversations ===
    await a.mouse.click(25, 28);
    await a.waitForTimeout(1500);
    await ss(a, '19-alice-conversations-after-chat');

    // === Try group creation ===
    // Click FAB
    await a.mouse.click(370, 705);
    await a.waitForTimeout(1000);
    await ss(a, '20-fab-menu');

    // Look for "New Group" option
    await a.mouse.click(300, 660);
    await a.waitForTimeout(2000);
    await ss(a, '21-after-fab-click');

    // === Wrong password test ===
    const wrongCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const wrong = await wrongCtx.newPage();
    await wrong.goto(APP);
    await wrong.waitForTimeout(4000);
    const vp = wrong.viewportSize()!;
    await wrong.mouse.click(vp.width / 2, vp.height / 2 - 40);
    await wrong.keyboard.type('alice');
    await wrong.keyboard.press('Tab');
    await wrong.keyboard.type('wrongpassword');
    await wrong.keyboard.press('Enter');
    await wrong.waitForTimeout(3000);
    await ss(wrong, '22-wrong-password');

    // === Register new user ===
    await wrong.goto(APP);
    await wrong.waitForTimeout(4000);
    // Click "Create an account"
    await wrong.mouse.click(vp.width / 2, vp.height / 2 + 120);
    await wrong.waitForTimeout(2000);
    await ss(wrong, '23-register-screen');

    // Cleanup
    await wrongCtx.close();
    await aliceCtx.close();
    await bobCtx.close();
    await charlieCtx.close();
  });
});
