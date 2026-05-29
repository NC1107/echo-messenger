/**
 * Two-client integration harness for voice-lounge canvas sync.
 *
 * Background
 * ----------
 * The voice-lounge canvas is the only product surface in Echo where state
 * sync is the user-visible behavior — when one participant draws, every
 * other participant must see the stroke appear in close to real time. Every
 * existing Playwright spec opens a single browser context, so the
 * `voice/`, `canvas/` surfaces in `audit_surfaces.ts` have been hard-skipped
 * with the rationale "needs LiveKit channel; capture from a real call".
 *
 * This harness lifts that limitation by spinning up two Playwright `Page`s
 * authenticated as two different users, joined to a shared group, and
 * exposing them to a scenario callback. See canvas_redesign.md (Phase 3,
 * PR D — "2-client integration harness").
 *
 * Browser-isolation choice: ONE browser instance, TWO contexts
 * ------------------------------------------------------------
 * Playwright's `browser.newContext()` already gives each context its own
 * cookie jar, localStorage, IndexedDB partition, and (critically for this
 * project) its own WebSocket connections — they are not shared with the
 * sibling context. We therefore use ONE browser process with TWO contexts:
 *
 *   pro:  ~2× faster than two browsers; lower memory; trace files share
 *         one Playwright runtime.
 *   con:  the contexts share the user-data-dir parent — but Playwright's
 *         non-persistent contexts (the default) deliberately avoid any
 *         on-disk overlap, so this is not observable.
 *
 * If a future test needs harder isolation (different platform features,
 * different prefers-reduced-motion, simulating two distinct phones), that
 * test can launch its own browser and call this harness's lower-level
 * primitives directly. For canvas-sync the two-context model is sufficient.
 *
 * What the harness does NOT do
 * ----------------------------
 * - It does not enter a LiveKit voice session. The LiveKit room is gated on
 *   `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` env vars that aren't present
 *   in CI. Canvas events are routed through Echo's own WebSocket hub
 *   (`/ws`, ticket-based) and do NOT require LiveKit to be running — that
 *   is by design (see `apps/server/src/ws/events/canvas.rs`). The first
 *   sync test that ships alongside this harness drives the canvas WS
 *   protocol directly rather than entering the lounge UI.
 *
 * - It does not seed users via the `seed_realistic_day.sh` / `seed_dms_only.sh`
 *   scripts. Those scripts produce timestamp-prefixed usernames so reruns
 *   don't collide on shared servers — that's the right call for fixtures
 *   meant to populate a dev DB, but it would force every test to discover
 *   its users' generated names. Instead the harness registers two test
 *   users via the public REST API with deterministic prefixes per run.
 */

import { Browser, BrowserContext, Page, TestType } from '@playwright/test';

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

export const SERVER = process.env.ECHO_SERVER || 'http://localhost:8080';
export const WEB_URL = process.env.ECHO_URL || 'http://localhost:8081';
export const APP_URL = `${WEB_URL}/?server=${encodeURIComponent(SERVER)}`;
const DEFAULT_PASSWORD = 'HarnessPass123!';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface HarnessUser {
  username: string;
  password: string;
  /** Populated after sign-in. */
  userId: string;
  /** Bearer JWT — useful for tests that want to drive REST or WS directly. */
  accessToken: string;
}

export interface HarnessClient {
  page: Page;
  context: BrowserContext;
  user: HarnessUser;
}

export interface HarnessSession {
  clientA: HarnessClient;
  clientB: HarnessClient;
  /** Shared group id both clients are members of. */
  groupId: string;
  /** Voice channel auto-created with the group (kind="voice", name="lounge"). */
  voiceChannelId: string;
}

export interface TwoClientOpts {
  /**
   * Pre-existing credentials. If omitted, the harness registers fresh users
   * via `/api/auth/register` with a timestamp-suffixed username so reruns
   * (and parallel CI shards) don't collide.
   */
  userA?: { username: string; password: string };
  userB?: { username: string; password: string };
  /**
   * Group name to create (or `null` to skip group creation entirely — only
   * useful if a test wants both users logged in but no shared conversation).
   * Defaults to a unique-per-run name.
   */
  groupName?: string | null;
}

// ---------------------------------------------------------------------------
// API helpers — kept self-contained so the harness has no peer-dep on the
// helpers in `group_messaging_ui.spec.ts`. Spec files come and go; this
// harness needs to outlive any single spec.
// ---------------------------------------------------------------------------

async function postJson<T = any>(
  path: string,
  body: Record<string, unknown>,
  token?: string,
): Promise<{ status: number; data: T }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${SERVER}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  const data = (await res.json().catch(() => ({}))) as T;
  return { status: res.status, data };
}

async function getJson<T = any>(
  path: string,
  token: string,
): Promise<{ status: number; data: T }> {
  const res = await fetch(`${SERVER}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = (await res.json().catch(() => ({}))) as T;
  return { status: res.status, data };
}

async function registerOrLogin(
  username: string,
  password: string,
): Promise<HarnessUser> {
  // Retry register on 429 with exponential backoff (1s/2s/4s/8s). The
  // rate-limiter is per-IP, so parallel Playwright workers register through
  // one bucket and the first slow shard hits 429 before later shards.
  // Mirrors the fix landed in commit e5fe02b4 for the deep-audit spec.
  let reg = await postJson('/api/auth/register', { username, password });
  for (let attempt = 0; attempt < 4 && reg.status === 429; attempt++) {
    const delayMs = 1000 * Math.pow(2, attempt);
    await new Promise((r) => setTimeout(r, delayMs));
    reg = await postJson('/api/auth/register', { username, password });
  }
  if (reg.status === 201 && reg.data?.access_token) {
    return {
      username,
      password,
      userId: reg.data.user_id,
      accessToken: reg.data.access_token,
    };
  }
  // Username already taken (parallel shard, retry, etc.) — fall through to
  // login. Spec retries depend on this idempotence (see #889).
  const login = await postJson('/api/auth/login', { username, password });
  if (login.status !== 200 || !login.data?.access_token) {
    throw new Error(
      `two-client harness: register+login failed for ${username}: ` +
        `register=${reg.status} login=${login.status}`,
    );
  }
  return {
    username,
    password,
    userId: login.data.user_id,
    accessToken: login.data.access_token,
  };
}

async function createGroupWithMember(
  ownerToken: string,
  groupName: string,
  memberId: string,
): Promise<{ groupId: string; voiceChannelId: string }> {
  const { status, data } = await postJson(
    '/api/groups',
    {
      name: groupName,
      description: 'two-client harness',
      is_public: true,
      is_encrypted: false,
      member_ids: [memberId],
    },
    ownerToken,
  );
  if (status !== 200 && status !== 201) {
    throw new Error(
      `two-client harness: createGroup failed: ${status} ${JSON.stringify(data)}`,
    );
  }
  const groupId: string = data.id ?? data.conversation_id;
  // Echo creates a default `lounge` voice channel on group create — see
  // apps/server/src/db/groups.rs ("VALUES ($1, 'lounge', 'voice', ...)").
  // Look it up so the canvas-sync scenario knows where to send events.
  const channels = await getJson<any[]>(`/api/groups/${groupId}/channels`, ownerToken);
  const lounge = (channels.data || []).find(
    (c) => c?.kind === 'voice' && c?.name === 'lounge',
  );
  if (!lounge?.id) {
    throw new Error(
      `two-client harness: no default voice channel found for group ${groupId}`,
    );
  }
  return { groupId, voiceChannelId: lounge.id };
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/**
 * Open two authenticated Playwright pages in the same browser, optionally
 * create a shared group with both users as members, hand them to the
 * scenario, and tear everything down. The harness owns the lifecycle —
 * scenarios should NOT call `page.close()` or `context.close()`.
 *
 * Usage from a spec:
 *
 *     test('canvas stroke syncs A→B', async ({ browser }, testInfo) => {
 *       await withTwoClients(browser, testInfo, async ({ clientA, clientB }) => {
 *         // ...drive A, assert B receives...
 *       });
 *     });
 */
export async function withTwoClients(
  browser: Browser,
  testInfo: { title: string },
  scenario: (session: HarnessSession) => Promise<void>,
  opts: TwoClientOpts = {},
): Promise<void> {
  // Unique-per-run suffix so parallel CI shards don't collide on usernames.
  // 8 hex chars from Date.now() + 4 random hex chars keeps the suffix short
  // and stable across one test invocation. `crypto.randomBytes` (not
  // `Math.random`) because CodeQL flags non-CSPRNG output reaching a
  // security-context sink — even when, as here, the "sink" is just a test
  // fixture username.
  const { randomBytes } = await import('node:crypto');
  const rand = randomBytes(2).toString('hex');
  const tag = `${Date.now().toString(36)}${rand}`.slice(0, 10);
  const userASpec = opts.userA ?? {
    username: `hA_${tag}`,
    password: DEFAULT_PASSWORD,
  };
  const userBSpec = opts.userB ?? {
    username: `hB_${tag}`,
    password: DEFAULT_PASSWORD,
  };

  const userA = await registerOrLogin(userASpec.username, userASpec.password);
  const userB = await registerOrLogin(userBSpec.username, userBSpec.password);

  let groupId = '';
  let voiceChannelId = '';
  if (opts.groupName !== null) {
    const groupName = opts.groupName ?? `harness ${tag}`;
    const created = await createGroupWithMember(
      userA.accessToken,
      groupName,
      userB.userId,
    );
    groupId = created.groupId;
    voiceChannelId = created.voiceChannelId;
  }

  const contextA = await browser.newContext();
  const contextB = await browser.newContext();
  const pageA = await contextA.newPage();
  const pageB = await contextB.newPage();

  try {
    await scenario({
      clientA: { page: pageA, context: contextA, user: userA },
      clientB: { page: pageB, context: contextB, user: userB },
      groupId,
      voiceChannelId,
    });
  } finally {
    // Always tear down even if the scenario threw — leaking browser
    // contexts in CI causes downstream tests to share Flutter state via
    // some platform quirks (CanvasKit's SharedWorker, web push), and
    // generally makes failure logs lie about which test killed things.
    await pageA.close().catch(() => {});
    await pageB.close().catch(() => {});
    await contextA.close().catch(() => {});
    await contextB.close().catch(() => {});
  }
  // testInfo is reserved for future per-test artifact paths (screenshots,
  // WS traces) but is intentionally unused right now — keeping it on the
  // signature lets us add per-test artifact dumps later without breaking
  // call sites.
  void testInfo;
}

// ---------------------------------------------------------------------------
// Low-level WS helper for canvas events
// ---------------------------------------------------------------------------

/**
 * Open a single-use WebSocket from `page`'s in-browser context, authenticated
 * by a fresh ticket minted from `accessToken`. The returned handle exposes
 * `send` / `waitForCanvasEvent` / `close` and is short-lived (callers should
 * close it before the scenario returns).
 *
 * Running the WebSocket *inside* the browser (rather than from the
 * Playwright runner) means CORS / cookie state matches a real client and
 * the same `?server=` override that the Flutter app uses is respected.
 */
export async function openCanvasWs(
  page: Page,
  accessToken: string,
): Promise<CanvasWsHandle> {
  // Mint a single-use WS ticket — JWT must never appear in the WS URL
  // (CLAUDE.md "Critical Conventions").
  const ticketRes = await postJson<{ ticket?: string }>(
    '/api/auth/ws-ticket',
    {},
    accessToken,
  );
  const ticket = ticketRes.data?.ticket;
  if (!ticket) {
    throw new Error(
      `two-client harness: ws-ticket failed (${ticketRes.status}): ` +
        JSON.stringify(ticketRes.data),
    );
  }
  const wsUrl = SERVER.replace(/^http/, 'ws') + `/ws?ticket=${ticket}`;

  // Install the WS in the page's context. We keep the connection open for
  // the lifetime of the handle and stream incoming canvas events into
  // window.__harnessCanvasEvents for the runner to poll.
  await page.evaluate((url) => {
    interface HarnessWindow extends Window {
      __harnessWs?: WebSocket;
      __harnessCanvasEvents?: unknown[];
      __harnessWsReady?: Promise<void>;
    }
    const w = window as HarnessWindow;
    w.__harnessCanvasEvents = [];
    const ws = new WebSocket(url);
    w.__harnessWs = ws;
    w.__harnessWsReady = new Promise<void>((resolve, reject) => {
      ws.addEventListener('open', () => resolve());
      ws.addEventListener('error', () => reject(new Error('ws error')));
    });
    ws.addEventListener('message', (ev) => {
      try {
        const parsed = JSON.parse(ev.data as string);
        if (parsed?.type === 'canvas_event') {
          (w.__harnessCanvasEvents as unknown[]).push(parsed);
        }
      } catch {
        // Heartbeat / non-JSON frames — ignore.
      }
    });
  }, wsUrl);

  // Wait for the open event before returning. Without this the first
  // `send` can race ahead of the handshake completing.
  await page.evaluate(async () => {
    interface HarnessWindow extends Window {
      __harnessWsReady?: Promise<void>;
    }
    const w = window as HarnessWindow;
    await w.__harnessWsReady;
  });

  return {
    page,
    async send(payload: Record<string, unknown>) {
      await page.evaluate((p) => {
        interface HarnessWindow extends Window {
          __harnessWs?: WebSocket;
        }
        (window as HarnessWindow).__harnessWs?.send(JSON.stringify(p));
      }, payload);
    },
    async waitForCanvasEvent(
      predicate: (ev: CanvasEventFrame) => boolean,
      timeoutMs = 5000,
    ): Promise<CanvasEventFrame> {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const events = await page.evaluate(() => {
          interface HarnessWindow extends Window {
            __harnessCanvasEvents?: unknown[];
          }
          return ((window as HarnessWindow).__harnessCanvasEvents ?? []) as unknown[];
        });
        const match = (events as CanvasEventFrame[]).find(predicate);
        if (match) return match;
        await page.waitForTimeout(100);
      }
      throw new Error(
        `two-client harness: no matching canvas_event within ${timeoutMs}ms`,
      );
    },
    async close() {
      await page.evaluate(() => {
        interface HarnessWindow extends Window {
          __harnessWs?: WebSocket;
        }
        (window as HarnessWindow).__harnessWs?.close();
      });
    },
  };
}

export interface CanvasEventFrame {
  type: 'canvas_event';
  channel_id: string;
  from_user_id: string;
  kind: string;
  payload: Record<string, unknown>;
}

export interface CanvasWsHandle {
  page: Page;
  send(payload: Record<string, unknown>): Promise<void>;
  waitForCanvasEvent(
    predicate: (ev: CanvasEventFrame) => boolean,
    timeoutMs?: number,
  ): Promise<CanvasEventFrame>;
  close(): Promise<void>;
}

// Re-export `TestType` so callers can fix the test fixture parameter type
// in one place if Playwright's signature shifts.
export type { TestType };
