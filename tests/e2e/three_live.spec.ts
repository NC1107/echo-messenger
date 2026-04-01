import { test, Page } from '@playwright/test';

const APP = 'http://localhost:8081';

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

test('3 live users - PAUSED for manual interaction', async ({ browser }) => {
  test.setTimeout(0); // No timeout -- wait forever until you close

  // Open 3 windows side by side
  const ctx1 = await browser.newContext({ viewport: { width: 500, height: 700 } });
  const ctx2 = await browser.newContext({ viewport: { width: 500, height: 700 } });
  const ctx3 = await browser.newContext({ viewport: { width: 500, height: 700 } });

  const alpha = await ctx1.newPage();
  const bravo = await ctx2.newPage();
  const charlie = await ctx3.newPage();

  console.log('Logging in alpha...');
  await login(alpha, 'alpha', 'pass1234');
  console.log('alpha logged in');

  console.log('Logging in bravo...');
  await login(bravo, 'bravo', 'pass1234');
  console.log('bravo logged in');

  console.log('Logging in charlie...');
  await login(charlie, 'charlie', 'pass1234');
  console.log('charlie logged in');

  console.log('');
  console.log('=== ALL 3 USERS LOGGED IN ===');
  console.log('3 browser windows should be visible on your desktop.');
  console.log('Waiting for you -- press Ctrl+C when done.');
  console.log('');

  // Keep alive forever -- user closes manually
  await new Promise(() => {});
});
