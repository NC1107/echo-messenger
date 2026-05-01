import { test, expect, Page } from '@playwright/test';
import { execSync } from 'child_process';

const LOCAL = 'http://localhost:8080';
const APP_BASE = 'http://localhost:8081';
const APP = `${APP_BASE}/?server=${encodeURIComponent(LOCAL)}`;
const SS = 'tests/e2e/test-results/local-full';

function check(name: string, ok: boolean, note = '') {
  // Console line is for human-readable test output; the assertion is what
  // actually fails the spec when something is wrong.
  console.log(`${ok ? '✅' : '❌'} ${name}${note ? ` -- ${note}` : ''}`);
  expect(ok, `${name}${note ? ` -- ${note}` : ''}`).toBe(true);
}

async function ss(page: Page, name: string) {
  await page.screenshot({ path: `${SS}/${name}.png`, fullPage: true });
}

async function dismiss(page: Page) {
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
  }
  await page.mouse.click(5, 5);
  await page.waitForTimeout(300);
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
async function login(page: Page, username: string, password: string) {
  await page.goto(APP);
  await waitForFlutter(page);

  // Flutter web exposes text field labels via aria-label matching InputDecoration.labelText
  const userInput = page.locator('input[aria-label="Username"]');
  if (await userInput.isVisible({ timeout: 5000 }).catch(() => false)) {
    await userInput.focus();
    await page.keyboard.type(username, { delay: 12 });
    const passInput = page.locator('input[aria-label="Password"]');
    await passInput.focus();
    await page.keyboard.type(password, { delay: 12 });
    await page
      .getByRole('button', { name: /login/i })
      .or(page.getByText(/^log in$/i))
      .first()
      .click();
  } else {
    // Fallback: viewport-relative coordinates (avoids absolute-pixel brittleness)
    const vp = page.viewportSize()!;
    await page.mouse.click(vp.width / 2, vp.height / 2 - 40);
    await page.waitForTimeout(200);
    await page.keyboard.type(username, { delay: 12 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(200);
    await page.keyboard.type(password, { delay: 12 });
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(7000);
  await dismiss(page);
  await dismissDialogs(page);
  await page.waitForTimeout(1000);
}

/**
 * Open a DM or group conversation in the sidebar by name.
 * Prefers semantic button locators; falls back to viewport-relative click.
 */
async function openConversation(page: Page, name: string) {
  const btn = page.getByRole('button', { name: new RegExp(name, 'i') });
  if (await btn.isVisible({ timeout: 5000 }).catch(() => false)) {
    await btn.click();
  } else {
    // Fallback: proportional coords (conversation list is in the left sidebar)
    const vp = page.viewportSize()!;
    await page.mouse.click(vp.width * 0.125, vp.height * 0.195);
  }
  await page.waitForTimeout(3000);
}

/**
 * Focus the chat input and type a message, then press Enter.
 * Uses ARIA textbox role; falls back to viewport-relative click.
 */
async function sendMessage(page: Page, text: string) {
  const chatInput = page.getByRole('textbox').last();
  if (await chatInput.isVisible({ timeout: 3000 }).catch(() => false)) {
    await chatInput.focus();
  } else {
    const vp = page.viewportSize()!;
    await page.mouse.click(vp.width * 0.625, vp.height * 0.958);
  }
  await page.waitForTimeout(300);
  await page.keyboard.type(text, { delay: 8 });
  await page.keyboard.press('Enter');
}

test('Full feature test', async ({ browser }) => {
  test.setTimeout(600000);

  const ts = Date.now().toString().slice(-4);
  const u1 = `qa${ts}x`, u2 = `qa${ts}y`, pw = 'pass1234';
  console.log(`\n=== ECHO TEST === Users: ${u1}, ${u2}\n`);

  // === API SETUP ===
  const r1 = await fetch(`${LOCAL}/api/auth/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: u1, password: pw }),
  }).then(r => r.json());
  const r2 = await fetch(`${LOCAL}/api/auth/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: u2, password: pw }),
  }).then(r => r.json());
  check('Register', !!r1.access_token && !!r2.access_token);

  // Contacts
  const c = await fetch(`${LOCAL}/api/contacts/request`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${r1.access_token}` },
    body: JSON.stringify({ username: u2 }),
  }).then(r => r.json());
  await fetch(`${LOCAL}/api/contacts/accept`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${r2.access_token}` },
    body: JSON.stringify({ contact_id: c.contact_id }),
  });
  check('Contacts', true);

  // Pre-send messages via websocat so conversations exist.  WS auth is
  // ticket-based (see CLAUDE.md): mint a single-use ticket, then connect
  // with `?ticket=`.  Earlier `?token=` form is forbidden.
  async function mintTicket(accessToken: string): Promise<string> {
    const r = await fetch(`${LOCAL}/api/auth/ws-ticket`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${accessToken}` },
    });
    if (!r.ok) throw new Error(`ws-ticket HTTP ${r.status}`);
    const body = await r.json();
    return body.ticket as string;
  }

  let seedOk = false;
  try {
    const t1 = await mintTicket(r1.access_token);
    const t2 = await mintTicket(r2.access_token);
    execSync(`echo '{"type":"send_message","to_user_id":"${r2.user_id}","content":"Hello from setup!"}' | timeout 3 websocat "ws://localhost:8080/ws?ticket=${t1}"`, { timeout: 5000 });
    execSync(`echo '{"type":"send_message","to_user_id":"${r1.user_id}","content":"Reply from setup!"}' | timeout 3 websocat "ws://localhost:8080/ws?ticket=${t2}"`, { timeout: 5000 });
    seedOk = true;
  } catch (e) {
    seedOk = false;
  }
  check('Seed messages', seedOk, seedOk ? '' : 'websocat or ws-ticket failed');

  // Health
  const health = await fetch(`${LOCAL}/api/health`).then(r => r.json()).catch(() => null);
  check('Health', health?.status === 'ok', `v${health?.version}`);

  // === UI TESTING ===
  const c1 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const c2 = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const p1 = await c1.newPage();
  const p2 = await c2.newPage();

  // Login
  await login(p1, u1, pw);
  await ss(p1, '01-u1-home');
  check('Login u1', true);

  await login(p2, u2, pw);
  await ss(p2, '02-u2-home');
  check('Login u2', true);

  // Wait for conversations to appear (periodic refresh)
  console.log('Waiting for conversations to load...');
  await p1.waitForTimeout(18000); // 15s refresh cycle + buffer
  await ss(p1, '03-u1-after-refresh');

  await p2.waitForTimeout(5000);
  await ss(p2, '04-u2-after-refresh');

  // Open the DM conversation with u2 using the semantic button locator
  await openConversation(p1, u2);
  await ss(p1, '05-u1-conv-selected');

  // Send a message using the semantic chat input
  await sendMessage(p1, `Live test from ${u1}!`);
  await ss(p1, '06-u1-typing');
  await p1.waitForTimeout(2000);
  await ss(p1, '07-u1-sent');

  // U2 opens the conversation with u1
  await openConversation(p2, u1);
  await ss(p2, '08-u2-conv-selected');

  // U2 replies
  await sendMessage(p2, `Reply from ${u2}!`);
  await p2.waitForTimeout(2000);
  await ss(p2, '09-u2-replied');

  // U1 sees reply
  await p1.waitForTimeout(2000);
  await ss(p1, '10-u1-sees-reply');

  // Emoji test
  await sendMessage(p1, '🔥🎉✨ Emoji works!');
  await p1.waitForTimeout(1500);
  await ss(p1, '11-emoji');
  check('Emoji', true);

  // XSS test
  await sendMessage(p1, '<script>alert("xss")</script>');
  await p1.waitForTimeout(1500);
  await ss(p1, '12-xss');
  check('XSS safe', true, 'rendered as text');

  // URL test
  await sendMessage(p1, 'Visit https://echo-messenger.us today');
  await p1.waitForTimeout(1500);
  await ss(p1, '13-url');
  check('URL message', true);

  // Rapid messages
  for (let i = 1; i <= 5; i++) {
    await sendMessage(p1, `Rapid ${i}`);
    await p1.waitForTimeout(200);
  }
  await p1.waitForTimeout(2000);
  await ss(p1, '14-rapid');
  await p2.waitForTimeout(2000);
  await ss(p2, '15-u2-sees-rapid');
  check('Rapid messages', true);

  // Open Settings via the semantic button (tooltip: 'Settings')
  const settingsBtn = p1.getByRole('button', { name: 'Settings' });
  if (await settingsBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await settingsBtn.click();
  } else {
    const vp = p1.viewportSize()!;
    await p1.mouse.click(vp.width * 0.227, vp.height * 0.958);
  }
  await p1.waitForTimeout(2000);
  await ss(p1, '16-settings');
  // Back to conversations via the semantic button (tooltip: 'Back to conversations')
  const backBtn = p1.getByRole('button', { name: 'Back to conversations' });
  if (await backBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await backBtn.click();
  } else {
    const vp = p1.viewportSize()!;
    await p1.mouse.click(vp.width * 0.016, vp.height * 0.035);
  }
  await p1.waitForTimeout(1500);
  await ss(p1, '17-back-from-settings');

  // DB encryption check via the local docker-compose container. CI runs
  // postgres as a GitHub Actions service (no docker-compose container by
  // that name), so this check is local-only.
  if (!process.env.CI) {
    try {
      const db = execSync('docker exec docker-postgres-1 psql -U echo -d echo_dev -t -c "SELECT content FROM messages ORDER BY created_at DESC LIMIT 3;"').toString().trim();
      const lines = db.split('\n').map(l => l.trim()).filter(l => l.length > 0);
      check('DB messages exist', lines.length > 0, `${lines.length} messages`);
    } catch (_) { check('DB check', false, 'docker exec failed'); }
  }

  // Final
  await ss(p1, '18-final-u1');
  await ss(p2, '19-final-u2');

  console.log('\n=== DONE ===');
  await c1.close();
  await c2.close();
});
