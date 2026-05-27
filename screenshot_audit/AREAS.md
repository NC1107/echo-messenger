# Screen catalogue

_Generated from `tests/e2e/audit_surfaces.ts` — do not edit by hand. Run the `generate-areas-md` test in the `audit` Playwright project to refresh._

**45 active surfaces** (captured by the spec) + **49 skipped** (manual or out of scope) = 94 catalogued.

## auth/

- `splash.png`
  > Splash screen — captured by bootstrap, brief window.
- `login.png` _(+mobile)_
- `register.png` _(+mobile)_
- `forgot-password.png`
- `reset-password.png` ⚠️ skipped
  > _skip: Requires reset-token email out-of-band; not worth scripting._
- `server-picker.png`
  > Triggered from login screen "Change server" link.
- `onboarding-welcome.png`
  > Captured during fresh-account bootstrap.
- `onboarding-presets.png`
  > The "familiar with" preset picker.
- `onboarding-final.png`

## home/

- `wide-3pane.png`
- `desktop-2pane.png`
  > 2-pane fits a 1280-wide window — narrower than wide-3pane.
- `conv-list-populated.png` _(+mobile, ×3 densities)_
- `no-conversation-placeholder.png`
  > Default empty right-pane state — no conv selected.
- `quick-switcher.png`
- `global-search.png`
- `keyboard-shortcuts.png`
- `collapsed-sidebar.png`
  > 60px sidebar — drag handle pull-through OR collapse button.

## chat/

- `dm.png` _(+mobile, ×3 layouts)_
- `group.png` _(+mobile)_
- `message-context-menu.png`
- `threads-inbox.png` _(+mobile)_
- `saved-messages.png` _(+mobile)_
- `safety-number.png`
- `reactions-stack.png` ⚠️ skipped
  > _skip: Needs a message with 6+ reactions; not yet seeded._
- `reactions-picker.png` ⚠️ skipped
  > _skip: Needs hover-then-react flow; brittle from script._
- `hover-bar.png` ⚠️ skipped
  > _skip: Hover state is brittle in CanvasKit; capture manually._
- `pin-pane.png` ⚠️ skipped
  > _skip: Requires pinned message; not yet seeded._
- `image-gallery.png` ⚠️ skipped
  > _skip: Requires uploaded image attachment; expensive to seed._
- `video-player.png` ⚠️ skipped
  > _skip: Requires uploaded video attachment; expensive to seed._
- `gif-picker.png` ⚠️ skipped
  > _skip: Needs Tenor API key + visible GIF results; capture manually._
- `drop-overlay.png` ⚠️ skipped
  > _skip: DragEnter must come from outside the browser; capture manually._

## group/

- `discover.png` _(+mobile)_
- `create-group.png` _(+mobile)_
- `join-group.png` _(+mobile)_
- `info-owner.png` _(+mobile)_
  > Owner sees danger zone (delete group).
- `info-member.png` ⚠️ skipped
  > _skip: Requires logging in as PEER user; second login session needed._
- `member-context-menu.png` ⚠️ skipped
  > _skip: Right-click on member; brittle from a single-client script._

## voice/

- `waiting.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `1-participant.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `multi-participants.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `spotlight.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `canvas-empty.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `canvas-with-strokes.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `canvas-with-image.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `canvas-with-text.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `screen-share-active.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `screen-share-window-draggable.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `fullscreen.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `participant-context-menu.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `dock-mic-submenu.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `dock-camera-submenu.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `dock-screenshare-submenu.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `dock-draw-submenu.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `call-metrics-chip.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._
- `lounge-header.png` ⚠️ skipped
  > _skip: Requires LiveKit channel; capture from a real call._

## canvas/

- `drawing-menu-pen.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-highlighter.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-line.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-rect.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-ellipse.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-text.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `drawing-menu-eraser.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `color-picker-dialog.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `background-dialog-desktop.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `background-dialog-mobile.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._
- `text-input-dialog.png` ⚠️ skipped
  > _skip: Dock is lounge-only; capture from a real voice channel._

## settings/

- `account.png` _(+mobile)_
- `appearance.png` _(+mobile)_
- `advanced-theme.png` _(+mobile)_
- `accessibility.png` _(+mobile)_
- `notifications.png` _(+mobile)_
- `privacy.png` _(+mobile)_
- `voice.png` _(+mobile)_
- `devices.png` _(+mobile)_
- `language.png` _(+mobile)_
- `data-storage.png` _(+mobile)_
- `status.png` _(+mobile)_
- `about.png` _(+mobile)_
- `advanced-theme-color-dialog.png`
- `about-feedback-dialog.png`
- `account-change-password-dialog.png` ⚠️ skipped
  > _skip: Triggered from account section but needs current password input — capture manually._
- `account-avatar-crop.png` ⚠️ skipped
  > _skip: Requires real file-upload; capture manually._
- `notifications-sound-picker.png` ⚠️ skipped
  > _skip: Nested under a tile that requires a real tap; brittle from script._
- `voice-device-picker.png` ⚠️ skipped
  > _skip: Web build does not expose device enumeration; capture from native._

## profiles/

- `contacts.png` _(+mobile)_
- `new-message-screen.png` _(+mobile)_
- `username-invite.png` _(+mobile)_
- `user-profile-screen.png` _(+mobile)_
- `user-profile-qr.png`

## modals/

- `confirm-destructive.png` ⚠️ skipped
  > _skip: Captured by group/info-owner (Delete group is the canonical example)._
- `toast-success.png` ⚠️ skipped
  > _skip: Toasts are <2s and theme inherits — not worth a flake-prone capture._
- `toast-error.png` ⚠️ skipped
  > _skip: Same as toast-success._
- `skeleton-loader.png` ⚠️ skipped
  > _skip: Transient — would need a slowed server to time correctly._

## admin/

- `admin-dashboard.png` ⚠️ skipped
  > _skip: Admin role required; capture manually with a privileged account._
