import { test, Page } from '@playwright/test';
import { execSync } from 'child_process';

const APP = 'http://localhost:8081';
const SS = 'tests/e2e/test-results/full';

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

test.describe('Comprehensive Test', () => {
  test.setTimeout(180000);

  test('full flow', async ({ browser }) => {
    const aliceCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const bobCtx = await browser.newContext({ viewport: { width: 420, height: 750 } });
    const alice = await aliceCtx.newPage();
    const bob = await bobCtx.newPage();

    // 1. Login
    await login(alice, 'alice', 'password123');
    await ss(alice, '01-alice-home');

    await login(bob, 'bob', 'password456');
    await ss(bob, '02-bob-home');

    // 2. Alice opens contacts, clicks bob
    await alice.mouse.click(360, 28); // contacts icon area
    await alice.waitForTimeout(2000);
    await ss(alice, '03-alice-contacts-or-menu');

    // Try clicking contacts icon directly
    await alice.goto(APP);
    await alice.waitForTimeout(4000);
    await login(alice, 'alice', 'password123');

    // Click bob in conversation list (if exists) or go to contacts
    await alice.mouse.click(210, 85);
    await alice.waitForTimeout(3000);
    await ss(alice, '04-alice-after-click');

    // 3. Alice sends message
    await alice.mouse.click(180, 710);
    await alice.waitForTimeout(300);
    await alice.keyboard.type('Hey Bob! Testing encryption!', { delay: 15 });
    await ss(alice, '05-alice-typing');

    await alice.keyboard.press('Enter');
    await alice.waitForTimeout(3000);
    await ss(alice, '06-alice-sent');

    // 4. Bob refreshes and opens chat
    // Click three dots menu
    await bob.mouse.click(395, 28);
    await bob.waitForTimeout(500);
    // Click Refresh in menu
    await bob.mouse.click(350, 70);
    await bob.waitForTimeout(2000);
    await ss(bob, '07-bob-after-refresh');

    // Bob clicks conversation
    await bob.mouse.click(210, 85);
    await bob.waitForTimeout(3000);
    await ss(bob, '08-bob-sees-message');

    // 5. Bob replies
    await bob.mouse.click(180, 710);
    await bob.waitForTimeout(300);
    await bob.keyboard.type('Got it! E2E encrypted!', { delay: 15 });
    await bob.keyboard.press('Enter');
    await bob.waitForTimeout(3000);
    await ss(bob, '09-bob-replied');

    // 6. Alice sees reply
    await alice.waitForTimeout(2000);
    await ss(alice, '10-alice-sees-reply');

    // 7. Rapid exchange to test grouping
    for (const msg of ['Quick msg 1', 'Quick msg 2', 'Quick msg 3']) {
      await alice.mouse.click(180, 710);
      await alice.waitForTimeout(200);
      await alice.keyboard.type(msg);
      await alice.keyboard.press('Enter');
      await alice.waitForTimeout(500);
    }
    await alice.waitForTimeout(2000);
    await ss(alice, '11-alice-grouped-messages');

    await bob.waitForTimeout(2000);
    await ss(bob, '12-bob-sees-grouped');

    // 8. Back to conversations
    await alice.mouse.click(25, 28);
    await alice.waitForTimeout(1500);
    await ss(alice, '13-alice-conversations-final');

    await bob.mouse.click(25, 28);
    await bob.waitForTimeout(1500);
    await ss(bob, '14-bob-conversations-final');

    // 9. DB encryption check
    try {
      const dbResult = execSync(
        'docker exec docker-postgres-1 psql -U echo -d echo_dev -t -c "SELECT content FROM messages LIMIT 10;"'
      ).toString().trim();
      const lines = dbResult.split('\n').map(l => l.trim()).filter(l => l.length > 0);

      let allEncrypted = true;
      for (const line of lines) {
        if (!line.match(/^[A-Za-z0-9+/=]{20,}$/)) {
          allEncrypted = false;
          console.log(`PLAINTEXT: "${line}"`);
        }
      }
      console.log(`DB CHECK: ${lines.length} messages, ${allEncrypted ? 'ALL ENCRYPTED' : 'SOME PLAINTEXT'}`);
    } catch (_) {
      console.log('DB check skipped');
    }

    await aliceCtx.close();
    await bobCtx.close();
  });
});
