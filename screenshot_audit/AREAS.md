# Screen catalogue

Single source of truth for the audit. The Playwright spec at
`tests/e2e/audit_tour.spec.ts` reads filenames from this list, and the
auditor uses it as a checklist.

Built by sweeping `apps/client/lib/src/screens/` and
`apps/client/lib/src/widgets/` for every distinct user-visible surface:
top-level screens, dialogs (`showDialog`), bottom sheets
(`showEchoBottomSheet`), popup menus, right-click context menus
(`onSecondaryTap*`), and inline overlays.

## auth/
- `splash.png`
- `login.png`
- `register.png`
- `forgot-password.png`
- `reset-password.png`
- `server-picker.png`
- `onboarding-wizard-welcome.png`
- `onboarding-wizard-presets.png`
- `onboarding-wizard-final.png`

## home/
- `conv-list-empty.png`
- `conv-list-populated.png`
- `desktop-2pane.png`
- `wide-3pane.png`
- `narrow-mobile.png`
- `collapsed-sidebar.png`
- `quick-switcher.png`
- `global-search.png`
- `keyboard-shortcuts.png`
- `whats-new.png`
- `welcome-card.png` — first-launch welcome card on empty chat
- `no-conversation-placeholder.png` — empty right pane when no conv selected
- `sidebar-create-menu.png` — right-click in sidebar empty area
- `conversation-context-menu.png` — right-click on a conv row
- `voice-dock-collapsed.png` — 60px sidebar
- `voice-dock-narrow.png` — 180px sidebar
- `voice-dock-full.png` — default sidebar
- `compose-fab.png` — mobile floating compose button

## chat/
- `dm.png`
- `group.png`
- `empty-conversation.png` — newly created chat, no messages yet
- `thread-panel.png`
- `threads-inbox.png`
- `hover-bar.png`
- `message-context-menu.png` — right-click on a message
- `reactions-stack.png` — message with overflow reaction stack
- `reactions-picker.png` — emoji picker for adding a reaction
- `reply-composer.png`
- `pin-pane.png`
- `forward-dialog.png`
- `image-gallery.png` — image gallery viewer (fullscreen media)
- `video-player.png` — fullscreen video player
- `mentions-autocomplete.png`
- `media-picker-sheet-mobile.png`
- `media-picker-panel-desktop.png`
- `gif-picker.png`
- `photo-gallery-picker.png`
- `drop-overlay.png` — drag-and-drop highlight active
- `message-search.png` — in-chat message search overlay
- `disappearing-msgs-sheet.png` — TTL picker
- `safety-number.png`
- `saved-messages.png`
- `chat-header-menu.png` — chat header overflow menu open
- `new-messages-pill.png` — "N new messages" pill visible
- `date-divider.png` — Today / Yesterday divider in scroll
- `unread-divider.png` — unread divider in scroll
- `system-timeline-message.png` — system event in timeline

## group/
- `info-owner.png`
- `info-member.png`
- `info-header-section.png` — header section close-up (name, avatar, description)
- `info-members-section.png` — full member list scrolled
- `info-channels-section.png` — text + voice channel list
- `info-invite-section.png` — invite section
- `info-disappearing-section.png` — disappearing-messages config section
- `info-danger-section.png` — danger zone (owner only)
- `member-context-menu.png` — right-click on a member
- `add-member-dialog.png`
- `invite-link-sheet.png`
- `delete-confirm.png`
- `leave-confirm.png`
- `kick-confirm.png`
- `discover.png`
- `discover-detail-sheet.png`
- `discover-empty.png` — no groups in discover yet
- `create-group.png`
- `join-group.png`
- `join-preview.png` — join preview scaffold (token / link preview)
- `token-join.png`
- `channel-create-dialog.png`
- `group-members-sheet.png` — from chat header

## voice/
- `waiting.png`
- `1-participant.png`
- `multi-participants.png`
- `spotlight.png`
- `canvas-empty.png`
- `canvas-with-strokes.png`
- `canvas-with-image.png`
- `canvas-with-text.png`
- `screen-share-active.png`
- `screen-share-window-draggable.png`
- `screen-select-dialog.png`
- `fullscreen.png`
- `participant-context-menu.png`
- `dock-mic-submenu.png`
- `dock-camera-submenu.png`
- `dock-screenshare-submenu.png`
- `dock-draw-submenu.png`
- `call-metrics-chip.png`
- `clear-board-confirm.png`
- `lounge-header.png` — lounge header bar close-up
- `participant-volume-popover.png` — per-participant volume slider

## canvas/
- `drawing-menu-pen.png`
- `drawing-menu-highlighter.png`
- `drawing-menu-line.png`
- `drawing-menu-rect.png`
- `drawing-menu-ellipse.png`
- `drawing-menu-text.png`
- `drawing-menu-eraser.png`
- `color-picker-dialog.png`
- `background-dialog-desktop.png`
- `background-dialog-mobile.png`
- `text-input-dialog.png`

## settings/
- `account.png`
- `account-change-password-dialog.png`
- `account-edit-profile.png`
- `account-avatar-crop.png`
- `account-qr-display.png`
- `appearance.png`
- `advanced-theme.png`
- `advanced-theme-color-dialog.png`
- `accessibility.png`
- `notifications.png`
- `notifications-sound-picker.png`
- `notifications-quiet-hours.png` — time picker tile
- `privacy.png`
- `privacy-destructive-dialog.png`
- `voice.png`
- `voice-device-picker.png`
- `devices.png`
- `devices-revoke-confirm.png`
- `language.png`
- `data-storage.png`
- `data-export-dialog.png`
- `status.png`
- `status-picker.png`
- `about.png`
- `about-feedback-dialog.png`
- `about-safety-number.png`

## admin/
- `admin-dashboard.png` — admin dashboard screen (admin only)

## profiles/
- `user-profile-sheet.png` — bottom sheet variant
- `user-profile-screen.png` — full-screen variant
- `user-profile-qr.png` — user profile QR card
- `username-invite.png`
- `contacts.png`
- `contacts-empty.png`
- `contact-add-by-username.png`
- `new-message-screen.png`
- `new-message-empty.png`

## modals/
- `confirm-destructive.png` — generic destructive confirm
- `confirm-non-destructive.png` — generic non-destructive confirm
- `bottom-sheet-shell.png` — generic Echo bottom sheet chrome
- `input-dialog.png` — generic input-dialog
- `toast-success.png`
- `toast-error.png`
- `toast-info.png`
- `skeleton-loader.png` — skeleton loading state
- `notification-permission.png` — native prompt (manual, not Playwright)

## audit format

Per area, an auditor records issues in `findings.md` (one per area):

```
| Theme | Screen | Issue | Severity |
|-------|--------|-------|----------|
| ember | drawing-menu-highlighter.png | Slider thumb invisible on amber bg | high |
```

Severities: **blocker** (broken UI), **high** (WCAG fail / clearly off
brand), **medium** (inconsistent), **low** (nice-to-have).

## what to look for, per screen

- **Hardcoded white / black** — text on accent buttons, badges, dialogs
- **Contrast** — pinned text, status pills, hover states meet WCAG AA (4.5:1)
- **Borders + dividers** — invisible in one theme, garish in another
- **Sent-message bubble** — uses theme accent, not hardcoded blue
- **Icons** — readable on both surface and surface-hover backgrounds
- **Toast / sheet shadows** — depth visible in light theme
- **Empty-state illustrations** — legible at default text-secondary alpha

## not in scope

- **iOS / Android-only OS dialogs** (broadcast picker, ReplayKit alert,
  FCM preview, CallKit). Manual capture into `screenshot_audit/_native/`.
- **Tooltips** (transient, inherit theme).
- **Loading skeletons** outside `modals/skeleton-loader.png` (covered by
  major screens captured before content loads).
