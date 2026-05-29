/**
 * Voice-lounge mobile / vertical-canvas audit.
 *
 * Origin
 * ------
 * User feedback 2026-05-28: "I'm not seeing good results on mobile / vertical
 * canvas" in the voice lounge. This spec exists to *document* the symptoms
 * with screenshots + soft assertions BEFORE any fix work starts, so that
 * follow-up agents see exactly what is broken and have evidence to confirm
 * a fix.
 *
 * Entry point
 * -----------
 * Run via `scripts/audit_lounge_mobile.sh` (which boots Postgres + server +
 * seed data first), or directly with:
 *
 *     cd tests/e2e
 *     npx playwright test voice_lounge_mobile_audit.spec.ts --project=maintained
 *
 * Output
 * ------
 *  - Numbered PNGs under  tests/e2e/output/screenshots/{portrait,landscape}/
 *  - Markdown report     tests/e2e/output/mobile-audit-report.md
 *
 * The spec uses soft assertions (`expect.soft(...)`) so a single clipped
 * button doesn't short-circuit the rest of the tour — the goal is to surface
 * EVERY observable problem in one run. The spec still fails at the end if
 * any soft assertion tripped, so CI surfaces the issue.
 *
 * Shape decisions (vs. driving Flutter widget gestures)
 * -----------------------------------------------------
 *  - Canvas state is driven over the existing `canvas_event` WS (see
 *    `harness/two-client.ts::openCanvasWs`). Playwright pointer-injection
 *    against CanvasKit is brittle and out of scope for this audit; the
 *    point of this spec is layout/clipping, not stroke recognition.
 *  - Only ONE Playwright user is needed for the visual sweep. A second
 *    headless user is registered via the REST API so the lounge has a
 *    "joinable" group with a default voice channel (group create
 *    auto-creates `lounge`), matching production reality.
 */
import { test, expect, Page, Locator } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const SERVER = process.env.ECHO_SERVER || 'http://localhost:8080';
const WEB_URL = process.env.ECHO_URL || 'http://localhost:8081';
const APP_URL = `${WEB_URL}/?server=${encodeURIComponent(SERVER)}`;

const OUTPUT_DIR = path.resolve(__dirname, 'output');
const SHOTS_DIR = path.join(OUTPUT_DIR, 'screenshots');
const REPORT_PATH = path.join(OUTPUT_DIR, 'mobile-audit-report.md');

const PORTRAIT = { width: 390, height: 844 };
const LANDSCAPE = { width: 844, height: 390 };

// ---------------------------------------------------------------------------
// Findings collector — populated by `recordCheck` and flushed to markdown.
// ---------------------------------------------------------------------------

interface Finding {
  orientation: 'portrait' | 'landscape';
  step: string;
  label: string;
  detail: string;
}

const findings: Finding[] = [];
let totalChecks = 0;
let failedChecks = 0;
const screenshotFiles: string[] = [];

function recordCheck(
  passed: boolean,
  finding: Omit<Finding, 'detail'> & { detail?: string },
) {
  totalChecks += 1;
  if (!passed) {
    failedChecks += 1;
    findings.push({
      orientation: finding.orientation,
      step: finding.step,
      label: finding.label,
      detail: finding.detail ?? '(no detail)',
    });
  }
}

// ---------------------------------------------------------------------------
// API helpers — kept inline so the spec has no cross-file coupling beyond
// the canvas-WS harness it borrows for stroke emission.
// ---------------------------------------------------------------------------

const TEST_PASSWORD = 'MobileAuditPass1!';

interface AuthedUser {
  username: string;
  userId: string;
  accessToken: string;
}

async function apiPost<T = Record<string, unknown>>(
  p: string,
  body: Record<string, unknown>,
  token?: string,
): Promise<{ status: number; data: T }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${SERVER}${p}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  const data = (await res.json().catch(() => ({}))) as T;
  return { status: res.status, data };
}

async function apiGet<T = Record<string, unknown>>(
  p: string,
  token: string,
): Promise<{ status: number; data: T }> {
  const res = await fetch(`${SERVER}${p}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = (await res.json().catch(() => ({}))) as T;
  return { status: res.status, data };
}

async function registerOrLogin(username: string, password: string): Promise<AuthedUser> {
  const reg = await apiPost<{ access_token?: string; user_id?: string }>(
    '/api/auth/register',
    { username, password },
  );
  if (reg.status === 201 && reg.data?.access_token && reg.data?.user_id) {
    return { username, userId: reg.data.user_id, accessToken: reg.data.access_token };
  }
  const login = await apiPost<{ access_token?: string; user_id?: string }>(
    '/api/auth/login',
    { username, password },
  );
  if (login.status !== 200 || !login.data?.access_token || !login.data?.user_id) {
    throw new Error(
      `mobile audit: register+login failed for ${username} ` +
        `(register=${reg.status}, login=${login.status})`,
    );
  }
  return { username, userId: login.data.user_id, accessToken: login.data.access_token };
}

async function createLoungeGroup(
  ownerToken: string,
  memberId: string,
  name: string,
): Promise<{ groupId: string; voiceChannelId: string }> {
  const created = await apiPost<{ id?: string; conversation_id?: string }>(
    '/api/groups',
    {
      name,
      description: 'mobile audit',
      is_public: true,
      is_encrypted: false,
      member_ids: [memberId],
    },
    ownerToken,
  );
  if (created.status !== 200 && created.status !== 201) {
    throw new Error(`mobile audit: createGroup failed: ${created.status}`);
  }
  const groupId = created.data?.id ?? created.data?.conversation_id;
  if (!groupId) throw new Error('mobile audit: createGroup returned no id');
  const channels = await apiGet<Array<{ id: string; kind: string; name: string }>>(
    `/api/groups/${groupId}/channels`,
    ownerToken,
  );
  const lounge = (channels.data || []).find((c) => c.kind === 'voice' && c.name === 'lounge');
  if (!lounge?.id) throw new Error('mobile audit: no lounge voice channel found');
  return { groupId, voiceChannelId: lounge.id };
}

// ---------------------------------------------------------------------------
// Flutter / UI helpers
// ---------------------------------------------------------------------------

async function waitForFlutter(page: Page) {
  // `flt-semantics` only appears after the platform plugin boots; gives us
  // a robust signal that the Dart isolate is alive without depending on
  // any particular widget being rendered.
  await page.waitForSelector('flt-semantics', { timeout: 30000 });
  await page.waitForTimeout(1500);
}

async function uiLogin(page: Page, username: string, password: string) {
  await page.goto(APP_URL);
  await waitForFlutter(page);
  // Login form fields are exposed via aria-label by the existing semantics
  // (`audit_tour.spec.ts` uses the same locators).
  const userInput = page.locator('input[aria-label="Username"]').first();
  if (await userInput.isVisible({ timeout: 4000 }).catch(() => false)) {
    await userInput.focus();
    await page.keyboard.type(username, { delay: 10 });
    const passInput = page.locator('input[aria-label="Password"]').first();
    await passInput.focus();
    await page.keyboard.type(password, { delay: 10 });
    const loginBtn = page
      .getByRole('button', { name: /^log ?in$|^sign in$/i })
      .first();
    await loginBtn.click({ timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(2500);
  }
  // Drain any onboarding gates so we land on the home shell.
  for (let i = 0; i < 6; i++) {
    const skip = page
      .getByRole('button', { name: /^skip|^next|continue|finish|done|get started/i })
      .first();
    if (!(await skip.isVisible({ timeout: 1000 }).catch(() => false))) break;
    await skip.click({ timeout: 3000 }).catch(() => {});
    await page.waitForTimeout(500);
  }
}

async function snap(
  page: Page,
  orientation: 'portrait' | 'landscape',
  name: string,
) {
  const dir = path.join(SHOTS_DIR, orientation);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${name}.png`);
  // fullPage:false — the entire concern is what fits within the phone
  // viewport, full-page would defeat the purpose.
  await page.screenshot({ path: file, fullPage: false });
  screenshotFiles.push(path.relative(OUTPUT_DIR, file));
}

async function tryClick(
  page: Page,
  matcher: RegExp,
  timeoutMs = 2000,
): Promise<boolean> {
  const role = page.getByRole('button', { name: matcher }).first();
  if (await role.isVisible({ timeout: timeoutMs }).catch(() => false)) {
    try {
      await role.click({ timeout: 4000 });
      return true;
    } catch {
      /* fall through to text locator */
    }
  }
  const txt = page.getByText(matcher).first();
  if (await txt.isVisible({ timeout: timeoutMs }).catch(() => false)) {
    try {
      await txt.click({ timeout: 4000 });
      return true;
    } catch {
      return false;
    }
  }
  return false;
}

// Bounding-box helpers — Playwright's `toBeInViewport` matcher is the
// canonical check but its diagnostics are sparse. We wrap it so failures
// land in the report with a concrete bbox to copy-paste.

async function assertInViewport(
  loc: Locator,
  viewport: { width: number; height: number },
  step: string,
  label: string,
  orientation: 'portrait' | 'landscape',
) {
  const visible = await loc.isVisible().catch(() => false);
  if (!visible) {
    recordCheck(false, {
      orientation,
      step,
      label,
      detail: 'locator not visible (element missing or hidden)',
    });
    return;
  }
  const box = await loc.boundingBox().catch(() => null);
  if (!box) {
    recordCheck(false, {
      orientation,
      step,
      label,
      detail: 'boundingBox() returned null',
    });
    return;
  }
  const fitsX = box.x >= 0 && box.x + box.width <= viewport.width + 1;
  const fitsY = box.y >= 0 && box.y + box.height <= viewport.height + 1;
  const passed = fitsX && fitsY;
  recordCheck(passed, {
    orientation,
    step,
    label,
    detail:
      `bbox=(x=${box.x.toFixed(1)}, y=${box.y.toFixed(1)}, ` +
      `w=${box.width.toFixed(1)}, h=${box.height.toFixed(1)}) ` +
      `viewport=${viewport.width}x${viewport.height} ` +
      `fitsX=${fitsX} fitsY=${fitsY}`,
  });
}

// Minimum tap-target check — Material/Apple HIG both call for 44pt min.
// We use 36 as a generous threshold: anything smaller is unambiguously a
// finger-trap on a phone.
async function assertTappable(
  loc: Locator,
  step: string,
  label: string,
  orientation: 'portrait' | 'landscape',
  minSide = 36,
) {
  const visible = await loc.isVisible().catch(() => false);
  if (!visible) {
    recordCheck(false, {
      orientation,
      step,
      label,
      detail: 'tap-target not visible',
    });
    return;
  }
  const box = await loc.boundingBox().catch(() => null);
  if (!box) {
    recordCheck(false, {
      orientation,
      step,
      label,
      detail: 'tap-target has no boundingBox',
    });
    return;
  }
  const passed = box.width >= minSide && box.height >= minSide;
  recordCheck(passed, {
    orientation,
    step,
    label,
    detail:
      `tap-target ${box.width.toFixed(1)}x${box.height.toFixed(1)} ` +
      `(min ${minSide}x${minSide})`,
  });
}

// ---------------------------------------------------------------------------
// Canvas WS — mirrors harness/two-client.ts::openCanvasWs but inlined so
// this spec stays self-contained (the harness module is wired to its own
// two-context lifecycle which we don't need here).
// ---------------------------------------------------------------------------

interface WsResult {
  ok: boolean;
  error?: string;
}

async function emitStrokeOverWs(
  page: Page,
  accessToken: string,
  channelId: string,
): Promise<WsResult> {
  try {
    const ticket = await apiPost<{ ticket?: string }>(
      '/api/auth/ws-ticket',
      {},
      accessToken,
    );
    const ticketStr = ticket.data?.ticket;
    if (!ticketStr) return { ok: false, error: `ws-ticket status=${ticket.status}` };
    const wsUrl = SERVER.replace(/^http/, 'ws') + `/ws?ticket=${ticketStr}`;

    const result = await page.evaluate<WsResult, { url: string; payload: Record<string, unknown> }>(
      ({ url, payload }) => {
        return new Promise<WsResult>((resolve) => {
          const ws = new WebSocket(url);
          const timeout = window.setTimeout(() => {
            try {
              ws.close();
            } catch (_e) {
              /* ignore */
            }
            resolve({ ok: false, error: 'ws open timeout' });
          }, 5000);
          ws.addEventListener('open', () => {
            try {
              ws.send(JSON.stringify(payload));
              // Give the server a beat to relay before closing.
              window.setTimeout(() => {
                window.clearTimeout(timeout);
                try {
                  ws.close();
                } catch (_e) {
                  /* ignore */
                }
                resolve({ ok: true });
              }, 250);
            } catch (e) {
              window.clearTimeout(timeout);
              resolve({ ok: false, error: String(e) });
            }
          });
          ws.addEventListener('error', () => {
            window.clearTimeout(timeout);
            resolve({ ok: false, error: 'ws error event' });
          });
        });
      },
      {
        url: wsUrl,
        payload: {
          type: 'canvas_event',
          channel_id: channelId,
          kind: 'stroke',
          payload: {
            id: '00000000-0000-4000-8000-00000000aud1',
            points: [
              { x: 30000.0, y: 30000.0 },
              { x: 35000.0, y: 32000.0 },
              { x: 40000.0, y: 36000.0 },
              { x: 45000.0, y: 42000.0 },
            ],
            color: '#ff0066',
            width: 6,
            tool: 'pen',
          },
        },
      },
    );
    return result;
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// ---------------------------------------------------------------------------
// Navigation helpers — best-effort. The lounge surface is gated behind a
// "join voice" affordance that varies by viewport; the audit must be
// resilient to layouts where it cannot reach the lounge UI (in that case
// the report records what was reached and why deeper steps were skipped).
// ---------------------------------------------------------------------------

interface LoungeReach {
  reachedHome: boolean;
  reachedConversation: boolean;
  reachedLounge: boolean;
}

async function tryReachLounge(page: Page, groupName: string): Promise<LoungeReach> {
  const reach: LoungeReach = {
    reachedHome: false,
    reachedConversation: false,
    reachedLounge: false,
  };

  // Wait for any post-login splash to settle.
  await page.waitForTimeout(1500);
  reach.reachedHome = true;

  // On narrow viewports the conversation list may be the only surface
  // visible until a group is chosen; just look for the group name and tap.
  const groupRow = page.getByText(new RegExp(groupName, 'i')).first();
  if (await groupRow.isVisible({ timeout: 4000 }).catch(() => false)) {
    await groupRow.click({ timeout: 4000 }).catch(() => {});
    await page.waitForTimeout(1500);
    reach.reachedConversation = true;
  } else {
    return reach;
  }

  // Look for any of the common lounge entry affordances.
  const joinPatterns: RegExp[] = [
    /join voice/i,
    /join lounge/i,
    /enter lounge/i,
    /^lounge$/i,
    /voice channel/i,
  ];
  for (const pat of joinPatterns) {
    if (await tryClick(page, pat, 2500)) {
      reach.reachedLounge = true;
      break;
    }
  }
  await page.waitForTimeout(2500);
  return reach;
}

// ---------------------------------------------------------------------------
// Per-orientation tour — every step is best-effort, captures a screenshot,
// then runs whatever assertions apply for that step. The spec keeps going
// even if a step's UI surface isn't reachable; the report makes the gap
// obvious.
// ---------------------------------------------------------------------------

interface TourCtx {
  page: Page;
  orientation: 'portrait' | 'landscape';
  viewport: { width: number; height: number };
  accessToken: string;
  voiceChannelId: string;
  groupName: string;
}

async function runLoungeSteps(ctx: TourCtx, stepPrefix: string) {
  const { page, orientation, viewport } = ctx;

  // --- 06: default lounge ---
  await snap(page, orientation, `${stepPrefix}06-lounge-default`);
  const backBtn = page.getByRole('button', { name: /back to chat|^back$/i }).first();
  await assertInViewport(backBtn, viewport, `${stepPrefix}06`, 'header back button', orientation);
  await assertTappable(backBtn, `${stepPrefix}06`, 'header back button tap size', orientation);

  // --- 07: tool menu open ---
  await tryClick(page, /^draw$|drawing|brush|tools/i, 2000);
  await page.waitForTimeout(500);
  await snap(page, orientation, `${stepPrefix}07-toolmenu-open`);

  // --- 08: brush selected ---
  await tryClick(page, /brush|pen/i, 1500);
  await snap(page, orientation, `${stepPrefix}08-brush-selected`);

  // --- 09: after stroke (driven via WS) ---
  const strokeResult = await emitStrokeOverWs(page, ctx.accessToken, ctx.voiceChannelId);
  await page.waitForTimeout(800);
  await snap(page, orientation, `${stepPrefix}09-after-stroke`);
  recordCheck(strokeResult.ok, {
    orientation,
    step: `${stepPrefix}09`,
    label: 'stroke emitted via WS',
    detail: strokeResult.error ?? 'ok',
  });

  // --- 10: eraser ---
  await tryClick(page, /eraser/i, 1500);
  await snap(page, orientation, `${stepPrefix}10-eraser-selected`);

  // --- 11: text tool ---
  await tryClick(page, /^text$|text tool/i, 1500);
  await snap(page, orientation, `${stepPrefix}11-text-tool`);

  // --- 12: shapes menu ---
  await tryClick(page, /shape|rect|circle/i, 1500);
  await snap(page, orientation, `${stepPrefix}12-shapes-menu`);

  // --- 13: color picker ---
  await tryClick(page, /color|colour/i, 1500);
  await snap(page, orientation, `${stepPrefix}13-color-picker`);

  // --- 14: width slider ---
  await tryClick(page, /width|stroke size|thickness/i, 1500);
  await snap(page, orientation, `${stepPrefix}14-width-slider`);

  // --- 15: clear ---
  // Don't actually confirm a clear — we just want the surface visible.
  await tryClick(page, /^clear$|clear canvas/i, 1500);
  await snap(page, orientation, `${stepPrefix}15-clear-button`);
  await page.keyboard.press('Escape').catch(() => {});

  // --- 16: reset view ---
  const resetBtn = page.getByRole('button', { name: /reset view|fit view/i }).first();
  if (await resetBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
    await assertInViewport(resetBtn, viewport, `${stepPrefix}16`, 'reset view button', orientation);
    await assertTappable(resetBtn, `${stepPrefix}16`, 'reset view tap size', orientation);
  }
  await snap(page, orientation, `${stepPrefix}16-reset-view`);

  // --- 17: bg picker ---
  await tryClick(page, /background|bg/i, 1500);
  await snap(page, orientation, `${stepPrefix}17-bg-picker`);
  await page.keyboard.press('Escape').catch(() => {});

  // --- 18: fullscreen ---
  await tryClick(page, /fullscreen|expand/i, 1500);
  await snap(page, orientation, `${stepPrefix}18-fullscreen`);
  await page.keyboard.press('Escape').catch(() => {});

  // --- 19: floating dock close-up + assertions ---
  await snap(page, orientation, `${stepPrefix}19-floating-dock`);
  const dockButtons: ReadonlyArray<readonly [string, RegExp]> = [
    ['mic dock button', /mute|unmute|^mic$/i],
    ['deafen dock button', /undeafen|deafen/i],
    ['camera dock button', /camera|video/i],
    ['screen share dock button', /share screen|stop sharing/i],
    ['leave dock button', /^leave$|leaving/i],
  ];
  for (const [label, pattern] of dockButtons) {
    const btn = page.getByRole('button', { name: pattern }).first();
    if (await btn.isVisible({ timeout: 1500 }).catch(() => false)) {
      await assertInViewport(btn, viewport, `${stepPrefix}19`, label, orientation);
      await assertTappable(btn, `${stepPrefix}19`, `${label} tap size`, orientation);
    } else {
      recordCheck(false, {
        orientation,
        step: `${stepPrefix}19`,
        label,
        detail: 'dock button not reachable in viewport',
      });
    }
  }

  // --- 20-22: submenus (mic / camera / screen-share) ---
  const submenus: ReadonlyArray<readonly [string, string, RegExp]> = [
    ['20', 'mic-submenu', /mute|unmute|^mic$/i],
    ['21', 'camera-submenu', /camera|video/i],
    ['22', 'screenshare-submenu', /share screen|stop sharing/i],
  ];
  for (const [stepNum, name, pattern] of submenus) {
    const trigger = page.getByRole('button', { name: pattern }).first();
    if (await trigger.isVisible({ timeout: 1500 }).catch(() => false)) {
      // Long-press / right-click opens the submenu in the lounge dock.
      await trigger.click({ button: 'right', timeout: 3000 }).catch(() => {});
      await page.waitForTimeout(600);
    }
    await snap(page, orientation, `${stepPrefix}${stepNum}-${name}`);
    await page.keyboard.press('Escape').catch(() => {});
    await page.waitForTimeout(300);
  }

  // --- 23: leave confirm ---
  const leaveBtn = page.getByRole('button', { name: /^leave$|leaving/i }).first();
  if (await leaveBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
    await leaveBtn.click({ timeout: 3000 }).catch(() => {});
    await page.waitForTimeout(700);
  }
  await snap(page, orientation, `${stepPrefix}23-leave-confirm`);
  // Cancel the leave so we can rotate and continue.
  await tryClick(page, /cancel|stay/i, 1500);
  await page.waitForTimeout(400);
}

// ---------------------------------------------------------------------------
// Report writer
// ---------------------------------------------------------------------------

function writeReport() {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const now = new Date().toISOString();
  const portrait = findings.filter((f) => f.orientation === 'portrait');
  const landscape = findings.filter((f) => f.orientation === 'landscape');
  const lines: string[] = [];
  lines.push('# Mobile / vertical voice-lounge audit');
  lines.push('');
  lines.push(`Generated: ${now}`);
  lines.push(
    `Viewport: ${PORTRAIT.width}x${PORTRAIT.height} (portrait), ` +
      `then ${LANDSCAPE.width}x${LANDSCAPE.height} (landscape)`,
  );
  lines.push('');
  lines.push('## Summary');
  lines.push('');
  lines.push(`- Total assertions: ${totalChecks}`);
  lines.push(`- Passed: ${totalChecks - failedChecks}`);
  lines.push(`- Failed: ${failedChecks}`);
  lines.push('');
  lines.push('## Findings (failed assertions, grouped)');
  lines.push('');
  lines.push('### Portrait');
  if (portrait.length === 0) {
    lines.push('- (none — but absence of evidence is not evidence of absence; review screenshots)');
  } else {
    for (const f of portrait) {
      lines.push(`- [step ${f.step}] ${f.label} — ${f.detail}`);
    }
  }
  lines.push('');
  lines.push('### Landscape');
  if (landscape.length === 0) {
    lines.push('- (none — but absence of evidence is not evidence of absence; review screenshots)');
  } else {
    for (const f of landscape) {
      lines.push(`- [step ${f.step}] ${f.label} — ${f.detail}`);
    }
  }
  lines.push('');
  lines.push('## Screenshots');
  lines.push('');
  for (const rel of screenshotFiles) {
    lines.push(`- ${rel}`);
  }
  lines.push('');
  fs.writeFileSync(REPORT_PATH, lines.join('\n'), 'utf8');
}

// ---------------------------------------------------------------------------
// Spec
// ---------------------------------------------------------------------------

test.describe('voice lounge mobile audit', () => {
  test.setTimeout(420_000);

  test('mobile portrait + landscape sweep', async ({ browser }) => {
    fs.mkdirSync(SHOTS_DIR, { recursive: true });

    const { randomBytes } = await import('node:crypto');
    const tag = `${Date.now().toString(36)}${randomBytes(2).toString('hex')}`.slice(0, 10);
    const userA = await registerOrLogin(`maA_${tag}`, TEST_PASSWORD);
    const userB = await registerOrLogin(`maB_${tag}`, TEST_PASSWORD);
    const groupName = `mobile audit ${tag}`;
    const { voiceChannelId } = await createLoungeGroup(
      userA.accessToken,
      userB.userId,
      groupName,
    );

    const context = await browser.newContext({ viewport: PORTRAIT });
    const page = await context.newPage();

    try {
      // --- Step 01: login screen ---
      await page.goto(APP_URL);
      await waitForFlutter(page);
      await snap(page, 'portrait', '01-login-screen');

      // --- Step 02: home after login ---
      await uiLogin(page, userA.username, TEST_PASSWORD);
      await snap(page, 'portrait', '02-home-after-login');

      // --- Step 03: group list ---
      // On mobile the conversation list is the home surface; capture as-is.
      await snap(page, 'portrait', '03-group-list');

      // --- Step 04: conversation open + Step 05: voice-lounge joining ---
      const reach = await tryReachLounge(page, groupName);
      recordCheck(reach.reachedConversation, {
        orientation: 'portrait',
        step: '04',
        label: 'reach conversation',
        detail: reach.reachedConversation
          ? 'ok'
          : 'group row not tappable from conversation list',
      });
      await snap(page, 'portrait', '04-conversation-open');
      recordCheck(reach.reachedLounge, {
        orientation: 'portrait',
        step: '05',
        label: 'reach lounge',
        detail: reach.reachedLounge
          ? 'ok'
          : 'no join-voice / join-lounge affordance visible on portrait viewport',
      });
      await snap(page, 'portrait', '05-voice-lounge-joining');

      if (reach.reachedLounge) {
        await runLoungeSteps(
          {
            page,
            orientation: 'portrait',
            viewport: PORTRAIT,
            accessToken: userA.accessToken,
            voiceChannelId,
            groupName,
          },
          'portrait-',
        );
      }

      // ----- Rotate to landscape, repeat lounge steps -----
      await page.setViewportSize(LANDSCAPE);
      await page.waitForTimeout(1000);
      // After rotation we may have been bounced back to the conversation; try
      // to re-enter the lounge.
      const reachLs = await tryReachLounge(page, groupName);
      await snap(page, 'landscape', 'landscape-05-voice-lounge-joining');
      recordCheck(reachLs.reachedLounge, {
        orientation: 'landscape',
        step: '05',
        label: 'reach lounge (landscape)',
        detail: reachLs.reachedLounge ? 'ok' : 'lounge not reachable after rotation',
      });
      if (reachLs.reachedLounge) {
        await runLoungeSteps(
          {
            page,
            orientation: 'landscape',
            viewport: LANDSCAPE,
            accessToken: userA.accessToken,
            voiceChannelId,
            groupName,
          },
          'landscape-',
        );
      }
    } finally {
      writeReport();
      await page.close().catch(() => {});
      await context.close().catch(() => {});
    }

    // The whole point of soft checks is to keep gathering evidence; this
    // line is the single hard assertion that fails the spec when ANY soft
    // check tripped, so CI sees red.
    expect.soft(
      failedChecks,
      `audit found ${failedChecks} issues — see ${REPORT_PATH}`,
    ).toBe(0);
    expect(failedChecks).toBe(0);
  });
});
