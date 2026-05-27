/**
 * The registry of every user-visible surface the audit captures.
 *
 * This is the single source of truth — `audit_tour.spec.ts` reads from this
 * list, and `screenshot_audit/AREAS.md` is generated from it (run the
 * `generate-areas-md` test in the audit project). No surface should live
 * only in AREAS.md or only in the spec — every surface is one entry here.
 *
 * To add a surface: add an entry. To suppress one you don't want captured:
 * set `skip: true` with a comment explaining why (so the omission is
 * visible in code review). To capture a surface in a non-default variant
 * (mobile viewport, comfortable density, etc.), declare it under
 * `variants`.
 */

import type { Page } from '@playwright/test';

export type Area =
  | 'auth'
  | 'home'
  | 'chat'
  | 'group'
  | 'voice'
  | 'canvas'
  | 'settings'
  | 'profiles'
  | 'modals'
  | 'admin';

export type Viewport = 'desktop' | 'mobile';
// Mirror enum names in apps/client/lib/src/providers/theme_provider.dart.
export type Density = 'cozy' | 'normal' | 'compact';
export type MessageLayout = 'bubbles' | 'compact' | 'plain';

/**
 * What the surface needs the world to look like to be reachable.
 *  - `fresh`: nothing required — works on a freshly registered user.
 *  - `seeded`: needs the DM + group seeded by `seedConversations()`.
 *  - `voice`: requires being inside a LiveKit voice channel (not yet
 *     scriptable from a single Playwright client; marks the surface as
 *     manual-capture).
 *  - `admin`: requires the admin role (manual-capture for now).
 */
export type Requires = 'fresh' | 'seeded' | 'voice' | 'admin';

export interface Surface {
  /** Stable filename slug. Combined with area to form `{theme}/{area}/{id}.png`. */
  id: string;
  area: Area;
  /** Drives the page to the state worth screenshotting. */
  reach: (page: Page, ctx: ReachContext) => Promise<void>;
  /** Defaults to 'seeded' (we always seed before the per-theme loop). */
  requires?: Requires;
  /** Extra variants beyond the default desktop × theme. */
  variants?: {
    /** Capture mobile (420×900) too. Defaults to false. */
    mobile?: boolean;
    /** Densities to capture. Defaults to ['standard']. */
    densities?: Density[];
    /** Chat message layouts. Defaults to ['standard']. */
    messageLayouts?: MessageLayout[];
  };
  /** When true the surface is intentionally NOT captured. Always include
   *  a `skipReason` so the omission is visible. */
  skip?: boolean;
  skipReason?: string;
  /** Free-text note that ends up in AREAS.md after the filename. */
  notes?: string;
}

export interface ReachContext {
  /** The seeded peer's username — used by reach handlers that need a
   *  predictable target (DM, group, etc.). */
  peerUser: string;
  /** Helper for clicking by visible label, falling through to text. */
  click: (label: RegExp, timeoutMs?: number) => Promise<boolean>;
  /** Navigate to an in-app GoRouter hash. */
  goto: (hash: string) => Promise<void>;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

export const SURFACES: Surface[] = [
  // -------------------------------------------------------------------------
  // auth/ — captured during the bootstrap test before the per-theme loop.
  // The registry entries here exist so AREAS.md still lists them, but the
  // capture logic for auth is bespoke (it can't run inside the logged-in
  // theme loop). reach() is a no-op marker.
  // -------------------------------------------------------------------------
  {
    id: 'splash',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    notes: 'Splash screen — captured by bootstrap, brief window.',
  },
  {
    id: 'login',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    variants: { mobile: true },
  },
  {
    id: 'register',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    variants: { mobile: true },
  },
  {
    id: 'forgot-password',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
  },
  {
    id: 'reset-password',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires reset-token email out-of-band; not worth scripting.',
  },
  {
    id: 'server-picker',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    notes: 'Triggered from login screen "Change server" link.',
  },
  {
    id: 'onboarding-welcome',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    notes: 'Captured during fresh-account bootstrap.',
  },
  {
    id: 'onboarding-presets',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
    notes: 'The "familiar with" preset picker.',
  },
  {
    id: 'onboarding-final',
    area: 'auth',
    requires: 'fresh',
    reach: async () => {},
  },

  // -------------------------------------------------------------------------
  // home/
  // The real route is `/home`; the spec previously used `/` and got 404s.
  // -------------------------------------------------------------------------
  {
    id: 'wide-3pane',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(800);
    },
  },
  {
    id: 'desktop-2pane',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.setViewportSize({ width: 1280, height: 800 });
      await p.waitForTimeout(800);
    },
    notes: '2-pane fits a 1280-wide window — narrower than wide-3pane.',
  },
  {
    id: 'conv-list-populated',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(800);
    },
    variants: {
      mobile: true,
      densities: ['cozy', 'normal', 'compact'],
    },
  },
  {
    id: 'no-conversation-placeholder',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(800);
    },
    notes: 'Default empty right-pane state — no conv selected.',
  },
  {
    id: 'quick-switcher',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      await p.keyboard.press('Control+k');
      await p.waitForTimeout(600);
    },
  },
  {
    id: 'global-search',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      await p.keyboard.press('Control+Shift+f');
      await p.waitForTimeout(600);
    },
  },
  {
    id: 'keyboard-shortcuts',
    area: 'home',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      await p.keyboard.press('Control+/');
      await p.waitForTimeout(600);
    },
  },
  {
    id: 'collapsed-sidebar',
    area: 'home',
    reach: async (p, { goto, click }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      await click(/collapse sidebar|hide sidebar/i, 1500);
      await p.waitForTimeout(600);
    },
    notes: '60px sidebar — drag handle pull-through OR collapse button.',
  },

  // -------------------------------------------------------------------------
  // chat/ — all flows go through /home first.
  // -------------------------------------------------------------------------
  {
    id: 'dm',
    area: 'chat',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(800);
      const conv = p.locator('flt-semantics[role="button"]').first();
      if (await conv.isVisible({ timeout: 1500 }).catch(() => false)) {
        await conv.click();
        await p.waitForTimeout(1500);
      }
    },
    variants: {
      mobile: true,
      messageLayouts: ['bubbles', 'compact', 'plain'],
    },
  },
  {
    id: 'group',
    area: 'chat',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      const group = p.getByText(/audit group/i).first();
      if (await group.isVisible({ timeout: 1500 }).catch(() => false)) {
        await group.click();
        await p.waitForTimeout(1500);
      }
    },
    variants: { mobile: true },
  },
  {
    id: 'message-context-menu',
    area: 'chat',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(600);
      const conv = p.locator('flt-semantics[role="button"]').first();
      if (await conv.isVisible({ timeout: 1500 }).catch(() => false)) {
        await conv.click();
        await p.waitForTimeout(1200);
        const msg = p.locator('flt-semantics').filter({ hasText: /audit|hey there/i }).first();
        if (await msg.isVisible({ timeout: 1500 }).catch(() => false)) {
          const box = await msg.boundingBox();
          if (box) {
            await p.mouse.click(box.x + box.width / 2, box.y + box.height / 2, {
              button: 'right',
            });
            await p.waitForTimeout(700);
          }
        }
      }
    },
  },
  {
    id: 'threads-inbox',
    area: 'chat',
    reach: async (p, { goto }) => {
      await goto('#/threads');
      await p.waitForTimeout(1000);
    },
    variants: { mobile: true },
  },
  {
    id: 'saved-messages',
    area: 'chat',
    reach: async (p, { goto }) => {
      await goto('#/saved');
      await p.waitForTimeout(1000);
    },
    variants: { mobile: true },
  },
  {
    id: 'safety-number',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason:
      'Route is /safety-number/:peerId — needs a concrete peer user id we can ' +
      'derive at runtime from the seeded peer. Will be reachable from a chat ' +
      'header tap once that flow is scripted.',
  },
  // Surfaces that need state we aren't currently seeding — flagged manual.
  {
    id: 'reactions-stack',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Needs a message with 6+ reactions; not yet seeded.',
  },
  {
    id: 'reactions-picker',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Needs hover-then-react flow; brittle from script.',
  },
  {
    id: 'hover-bar',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Hover state is brittle in CanvasKit; capture manually.',
  },
  {
    id: 'pin-pane',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires pinned message; not yet seeded.',
  },
  {
    id: 'image-gallery',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires uploaded image attachment; expensive to seed.',
  },
  {
    id: 'video-player',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires uploaded video attachment; expensive to seed.',
  },
  {
    id: 'gif-picker',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'Needs Tenor API key + visible GIF results; capture manually.',
  },
  {
    id: 'drop-overlay',
    area: 'chat',
    reach: async () => {},
    skip: true,
    skipReason: 'DragEnter must come from outside the browser; capture manually.',
  },

  // -------------------------------------------------------------------------
  // group/
  // -------------------------------------------------------------------------
  {
    id: 'discover',
    area: 'group',
    reach: async (p, { goto }) => {
      await goto('#/discover-groups');
      await p.waitForTimeout(1000);
    },
    variants: { mobile: true },
  },
  {
    id: 'create-group',
    area: 'group',
    reach: async (p, { goto }) => {
      await goto('#/create-group');
      await p.waitForTimeout(1000);
    },
    variants: { mobile: true },
  },
  {
    id: 'join-group',
    area: 'group',
    reach: async () => {},
    skip: true,
    skipReason:
      '/join/:groupId needs a concrete invite id. Capture from a real invite ' +
      'link or seed an invite via API in a follow-up.',
  },
  {
    id: 'info-owner',
    area: 'group',
    reach: async (p, { goto }) => {
      await goto('#/home');
      await p.waitForTimeout(800);
      const group = p.getByText(/audit group/i).first();
      if (await group.isVisible({ timeout: 1500 }).catch(() => false)) {
        await group.click();
        await p.waitForTimeout(1200);
        const header = p.getByText(/audit group/i).first();
        if (await header.isVisible({ timeout: 1500 }).catch(() => false)) {
          await header.click();
          await p.waitForTimeout(1200);
        }
      }
    },
    variants: { mobile: true },
    notes: 'Owner sees danger zone (delete group).',
  },
  {
    id: 'info-member',
    area: 'group',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires logging in as PEER user; second login session needed.',
  },
  {
    id: 'member-context-menu',
    area: 'group',
    reach: async () => {},
    skip: true,
    skipReason: 'Right-click on member; brittle from a single-client script.',
  },

  // -------------------------------------------------------------------------
  // voice/ — every surface requires being inside a LiveKit channel with at
  // least one peer, which a single Playwright client can't fake. All marked
  // skip for now; revisit with a 2-client harness later.
  // -------------------------------------------------------------------------
  ...(
    [
      'waiting',
      '1-participant',
      'multi-participants',
      'spotlight',
      'canvas-empty',
      'canvas-with-strokes',
      'canvas-with-image',
      'canvas-with-text',
      'screen-share-active',
      'screen-share-window-draggable',
      'fullscreen',
      'participant-context-menu',
      'dock-mic-submenu',
      'dock-camera-submenu',
      'dock-screenshare-submenu',
      'dock-draw-submenu',
      'call-metrics-chip',
      'lounge-header',
    ] as const
  ).map<Surface>((id) => ({
    id,
    area: 'voice',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires LiveKit channel; capture from a real call.',
  })),

  // -------------------------------------------------------------------------
  // canvas/ — drawing tools menu states are reachable on desktop without a
  // voice channel only if the dock is exposed. Today the dock only renders
  // inside the lounge, so these inherit the voice/ skip.
  // -------------------------------------------------------------------------
  ...(
    [
      'drawing-menu-pen',
      'drawing-menu-highlighter',
      'drawing-menu-line',
      'drawing-menu-rect',
      'drawing-menu-ellipse',
      'drawing-menu-text',
      'drawing-menu-eraser',
      'color-picker-dialog',
      'background-dialog-desktop',
      'background-dialog-mobile',
      'text-input-dialog',
    ] as const
  ).map<Surface>((id) => ({
    id,
    area: 'canvas',
    reach: async () => {},
    skip: true,
    skipReason: 'Dock is lounge-only; capture from a real voice channel.',
  })),

  // -------------------------------------------------------------------------
  // settings/
  // Settings is a SINGLE route (/settings) with section tiles tapped to
  // open the section's content. There are no per-section URLs. Each
  // capture below navigates to /settings then taps the tile by its
  // visible label.
  // -------------------------------------------------------------------------
  ...(
    [
      ['account', 'Profile'],           // SettingsSection.profile renders the account view
      ['appearance', 'Appearance'],
      ['accessibility', 'Accessibility'],
      ['notifications', 'Notifications'],
      ['privacy', 'Privacy'],
      ['voice', 'Voice & Video'],
      ['devices', 'Devices'],
      ['language', 'Language'],
      ['data-storage', 'Storage'],
      ['status', 'Status'],
      ['about', 'About'],
    ] as const
  ).map<Surface>(([id, label]) => ({
    id,
    area: 'settings',
    reach: async (p, { goto, click }) => {
      await goto('#/settings');
      await p.waitForTimeout(800);
      await click(new RegExp(`^${label}$`, 'i'), 2000);
      await p.waitForTimeout(800);
    },
    variants: { mobile: true },
  })),
  {
    id: 'advanced-theme',
    area: 'settings',
    reach: async (p, { goto, click }) => {
      await goto('#/settings');
      await p.waitForTimeout(800);
      await click(/^Appearance$/i, 2000);
      await p.waitForTimeout(800);
      await click(/advanced|custom theme|customise|customize/i, 1500);
      await p.waitForTimeout(800);
    },
  },
  {
    id: 'advanced-theme-color-dialog',
    area: 'settings',
    reach: async (p, { goto, click }) => {
      await goto('#/settings');
      await p.waitForTimeout(800);
      await click(/^Appearance$/i, 2000);
      await p.waitForTimeout(800);
      await click(/advanced|custom theme|customise|customize/i, 1500);
      await p.waitForTimeout(800);
      await click(/pick custom accent|custom accent|choose colour|choose color/i, 1500);
      await p.waitForTimeout(800);
    },
  },
  {
    id: 'about-feedback-dialog',
    area: 'settings',
    reach: async (p, { goto, click }) => {
      await goto('#/settings');
      await p.waitForTimeout(800);
      await click(/^About$/i, 2000);
      await p.waitForTimeout(800);
      await click(/send feedback|feedback/i, 1500);
      await p.waitForTimeout(600);
    },
  },
  // Surfaces that need flows we don't currently script.
  {
    id: 'account-change-password-dialog',
    area: 'settings',
    reach: async () => {},
    skip: true,
    skipReason: 'Triggered from account section but needs current password input — capture manually.',
  },
  {
    id: 'account-avatar-crop',
    area: 'settings',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires real file-upload; capture manually.',
  },
  {
    id: 'notifications-sound-picker',
    area: 'settings',
    reach: async () => {},
    skip: true,
    skipReason: 'Nested under a tile that requires a real tap; brittle from script.',
  },
  {
    id: 'voice-device-picker',
    area: 'settings',
    reach: async () => {},
    skip: true,
    skipReason: 'Web build does not expose device enumeration; capture from native.',
  },

  // -------------------------------------------------------------------------
  // profiles/
  // -------------------------------------------------------------------------
  {
    id: 'contacts',
    area: 'profiles',
    reach: async (p, { goto }) => {
      await goto('#/contacts');
      await p.waitForTimeout(1000);
    },
    variants: { mobile: true },
  },
  {
    id: 'new-message-screen',
    area: 'profiles',
    reach: async () => {},
    skip: true,
    skipReason:
      'No /new-message route — surface is a bottom-sheet opened from the home ' +
      'screen via the "+" or "Start a new chat" button. Will be reached via ' +
      'click flow in a follow-up.',
  },
  {
    id: 'username-invite',
    area: 'profiles',
    reach: async () => {},
    skip: true,
    skipReason:
      'No standalone /invite route — username-invite is a sub-screen inside ' +
      'Contacts/Settings. Capture via click flow in a follow-up.',
  },
  {
    id: 'user-profile-screen',
    area: 'profiles',
    reach: async () => {},
    skip: true,
    skipReason:
      '/profile/:userId requires a userId — bare /profile redirects to /home. ' +
      'Reach by tapping a user header (DM) in a follow-up.',
  },
  {
    id: 'user-profile-qr',
    area: 'profiles',
    reach: async () => {},
    skip: true,
    skipReason: 'Requires the user-profile-screen to load first; same skip rationale.',
  },

  // -------------------------------------------------------------------------
  // modals/ — most generic shells overlap with screen-specific captures, so
  // only the truly generic ones live here. The rest are caught alongside
  // their parent screen.
  // -------------------------------------------------------------------------
  {
    id: 'confirm-destructive',
    area: 'modals',
    reach: async () => {},
    skip: true,
    skipReason: 'Captured by group/info-owner (Delete group is the canonical example).',
  },
  {
    id: 'toast-success',
    area: 'modals',
    reach: async () => {},
    skip: true,
    skipReason: 'Toasts are <2s and theme inherits — not worth a flake-prone capture.',
  },
  {
    id: 'toast-error',
    area: 'modals',
    reach: async () => {},
    skip: true,
    skipReason: 'Same as toast-success.',
  },
  {
    id: 'skeleton-loader',
    area: 'modals',
    reach: async () => {},
    skip: true,
    skipReason: 'Transient — would need a slowed server to time correctly.',
  },

  // -------------------------------------------------------------------------
  // admin/
  // -------------------------------------------------------------------------
  {
    id: 'admin-dashboard',
    area: 'admin',
    reach: async () => {},
    skip: true,
    skipReason: 'Admin role required; capture manually with a privileged account.',
  },
];

// ---------------------------------------------------------------------------
// Generated AREAS.md helper — keeps the catalogue in sync with the registry.
// ---------------------------------------------------------------------------

export function generateAreasMarkdown(): string {
  const lines: string[] = [];
  lines.push('# Screen catalogue\n');
  lines.push(
    '_Generated from `tests/e2e/audit_surfaces.ts` — do not edit by hand. Run the `generate-areas-md` test in the `audit` Playwright project to refresh._\n',
  );

  const totalActive = SURFACES.filter((s) => !s.skip).length;
  const totalSkipped = SURFACES.filter((s) => s.skip).length;
  lines.push(
    `**${totalActive} active surfaces** (captured by the spec) + **${totalSkipped} skipped** (manual or out of scope) = ${SURFACES.length} catalogued.\n`,
  );

  const byArea = new Map<Area, Surface[]>();
  for (const s of SURFACES) {
    if (!byArea.has(s.area)) byArea.set(s.area, []);
    byArea.get(s.area)!.push(s);
  }

  for (const [area, surfaces] of byArea) {
    lines.push(`## ${area}/\n`);
    for (const s of surfaces) {
      const marker = s.skip ? ' ⚠️ skipped' : '';
      const variantTags: string[] = [];
      if (s.variants?.mobile) variantTags.push('+mobile');
      if (s.variants?.densities && s.variants.densities.length > 1) {
        variantTags.push(`×${s.variants.densities.length} densities`);
      }
      if (s.variants?.messageLayouts && s.variants.messageLayouts.length > 1) {
        variantTags.push(`×${s.variants.messageLayouts.length} layouts`);
      }
      const tags = variantTags.length > 0 ? ` _(${variantTags.join(', ')})_` : '';
      lines.push(`- \`${s.id}.png\`${tags}${marker}`);
      if (s.notes) lines.push(`  > ${s.notes}`);
      if (s.skip && s.skipReason) lines.push(`  > _skip: ${s.skipReason}_`);
    }
    lines.push('');
  }

  return lines.join('\n');
}
