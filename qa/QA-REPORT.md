# QA Report — Echo Messenger Production Testing
**Date**: 2026-04-06
**Site**: https://echo-messenger.us
**Account**: admin_tester
**Method**: Playwright MCP (headless Chromium, 1920x993 viewport)

## Test Summary

| Area | Status | Notes |
|------|--------|-------|
| Splash → Auto-login | PASS | Navigates from /splash to /home in ~5s |
| Group selection | PASS | Sidebar click selects group, header shows name + member count |
| Group message send | PASS | Message sent via Enter, appears right-aligned with timestamp + checkmark |
| Markdown rendering | PASS | **bold**, *italic*, `code` all render correctly in message bubbles |
| Channel tabs | PASS | # general and 🔊 lounge tabs visible and functional |
| Voice join dialog | PASS | Clicking lounge shows "Join Voice Channel?" confirmation |
| Settings navigation | PASS | Direct URL /settings loads correctly |
| Settings - Account | PASS | Username, avatar, upload/QR buttons visible |
| Settings - Privacy | PASS | Read receipts toggle, encryption section, reset keys |
| Settings - Audio | PASS | Input/output device dropdowns, sensitivity/volume sliders, PTT |
| Settings - Debug Logs | PASS | 200-entry ring buffer, colored level badges, clear button |
| Contacts tab | PASS | Empty state with "Add Contact" button |
| Groups tab | PASS | All groups listed with previews |
| Discover Groups | PASS | Public groups listed with Join/Joined badges, search bar |
| Join link deep link | PASS | /join/:groupId navigates to join screen correctly |
| WebSocket stability | ISSUE | Disconnects every ~4 minutes, auto-reconnects (1000ms, attempt 1/10) |

## Bugs Found

### Critical
1. **WebSocket drops every ~4 minutes** — Debug logs show repeated "Connection closed (onDone) → Reconnecting in 1000ms → Connected" cycle. Possible server-side idle timeout or proxy timeout (Traefik/Cloudflare).

### Missing Features (confirmed from user reports)
2. **No Notifications settings tab** — No way to toggle sound, test notifications, or configure notification behavior
3. **No camera selector** — Audio settings has mic/speaker but no camera dropdown for video calls
4. **No "Allow Unencrypted DMs" toggle** — Was in old builds but missing from current Privacy settings

### UI/UX Issues
5. **Sidebar preview shows raw markdown** — "You: \*\*bold text\*\* and \*italic text\*..." instead of styled preview
6. **Hover actions not visible** — Could not trigger message hover overlay in headless Playwright (may work in real browser — needs manual verification)
7. **Settings cog hard to click** — Mouse click at documented coordinates (291, 966) didn't navigate; had to use direct URL

### Playwright Testing Limitations
- Flutter CanvasKit renders as single `<canvas>` — no DOM elements to interact with
- Text input requires: (1) click at exact viewport coords to focus TextField, (2) find hidden `<textarea>` created by Flutter, (3) fill via Playwright's DOM API
- Hover states don't trigger reliably in headless mode — can't test hover actions (pin, reply, edit, delete, reactions)
- Voice/video/screen share can't be tested in headless (no media devices)
- File upload can't be tested (no file dialog interaction in CanvasKit)

## What Could NOT Be Tested via Playwright
- DM messaging + encryption (no DM contacts on this account)
- Pin/unpin messages (requires hover actions)
- Reply to messages (requires hover actions)
- Edit/delete messages (requires hover actions)
- Reactions (requires hover + click)
- Voice channels (no microphone in headless)
- Video calling (no camera in headless)
- Screen sharing (no display media in headless)
- Image/file upload (requires file dialog)
- Mobile responsive layout (fixed 1920x993 viewport)
- Scroll position caching (only 2 messages, can't test scroll behavior)

## Screenshots Captured
- qa/01-fresh-load.png — Initial home page after auto-login
- qa/02-gaming-lounge.png — Gaming Lounge group selected (wrong click hit Tech Talk)
- qa/03-music-corner.png — Gaming Lounge opened correctly
- qa/04-typing-message.png — Text input focus issue (click didn't focus)
- qa/05-after-tab-type.png — Tab navigation triggered voice join dialog
- qa/06-after-pointer-type.png — Pointer event dispatch attempt
- qa/07-dialog-dismissed.png — Voice join dialog + WS reconnecting
- qa/08-dialog-after-outside-click.png — Dialog dismissed, WS reconnected
- qa/09-text-in-input.png — Text successfully entered via textarea fill
- qa/10-message-sent.png — Message sent and displayed
- qa/11-markdown-message.png — Markdown rendering verified
- qa/14-settings-page.png — Settings Account tab
- qa/15-debug-logs.png — Debug Logs section (initial attempt)
- qa/17-debug-logs-v3.png — Debug Logs section (successful)
- qa/18-audio-settings.png — Audio settings tab
- qa/19-privacy-settings.png — Privacy settings tab
- qa/20-contacts-tab.png — Contacts empty state
- qa/21-groups-tab.png — Groups tab with all groups
- qa/22-discover-groups.png — Discover Groups page
- qa/23-join-link.png — Join link deep navigation
- qa/24-gaming-lounge-messages.png — Messages with markdown
- qa/25-message-hover.png — Hover attempt (no overlay visible)

## Recommendations
1. **For comprehensive QA**: Use real browser testing (non-headless) for hover actions, voice, video, file upload
2. **WebSocket stability**: Investigate 4-minute disconnect cycle — likely Cloudflare/Traefik proxy timeout
3. **Add notification settings**: Sound toggle + test notification button
4. **Add camera selector**: Enumerate cameras in Audio/Video settings
5. **Consider Selenium or real-device testing** for features that can't be tested in headless CanvasKit
