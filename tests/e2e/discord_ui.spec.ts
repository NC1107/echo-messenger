import { test, Page } from '@playwright/test';
const APP = 'http://localhost:8081';
const SS = 'tests/e2e/test-results/discord-ui';

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function login(page: Page, username: string, password: string) {
  await page.goto(APP);
  await page.waitForTimeout(4000);
  const vp = page.viewportSize()!;
  await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
  await page.waitForTimeout(200);
  await page.keyboard.type(username, { delay: 20 });
  await page.keyboard.press('Tab');
  await page.waitForTimeout(200);
  await page.keyboard.type(password, { delay: 20 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(6000);
}

test('Discord-like UI', async ({ browser }) => {
  test.setTimeout(120000);

  // Wide viewport to see three panels
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await ctx.newPage();

  // Login screen
  await page.goto(APP);
  await page.waitForTimeout(4000);
  await ss(page, '01-login');

  // Login and see the new home layout
  await login(page, 'alpha', 'pass1234');
  await ss(page, '02-home-three-panel');

  // Click on a conversation in middle panel
  await page.mouse.click(200, 200);
  await page.waitForTimeout(3000);
  await ss(page, '03-conversation-selected');

  // Type a message
  await page.mouse.click(800, 680);
  await page.waitForTimeout(200);
  await page.keyboard.type('Testing the Discord UI! Looks amazing!', { delay: 15 });
  await ss(page, '04-typing-message');

  // Send
  await page.keyboard.press('Enter');
  await page.waitForTimeout(2000);
  await ss(page, '05-message-sent');

  // Second user
  const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page2 = await ctx2.newPage();
  await login(page2, 'bravo', 'pass1234');
  await ss(page2, '06-bravo-home');

  // Bravo clicks conversation
  await page2.mouse.click(200, 200);
  await page2.waitForTimeout(3000);
  await ss(page2, '07-bravo-sees-chat');

  // Bravo replies
  await page2.mouse.click(800, 680);
  await page2.waitForTimeout(200);
  await page2.keyboard.type('The new UI looks great! Very Discord-like!', { delay: 15 });
  await page2.keyboard.press('Enter');
  await page2.waitForTimeout(2000);
  await ss(page2, '08-bravo-replied');

  // Alpha sees reply
  await page.waitForTimeout(2000);
  await ss(page, '09-alpha-sees-reply');

  // Narrow viewport test (mobile-like)
  await page.setViewportSize({ width: 400, height: 700 });
  await page.waitForTimeout(1000);
  await ss(page, '10-narrow-mobile-view');

  await ctx.close();
  await ctx2.close();
});
