# Tomorrow's Tasks -- Echo Messenger

Feedback from live testing session (April 2, 2026). 26 items categorized and planned.

---

## Critical (App-Breaking)

### 1. Voice chat not working -- zero audio
**Problem:** No audio flowing between peers on any platform combo (AppImage ↔ Web, Web ↔ Web). Need deep research.

**Investigation plan:**
- Check if `RTCVideoView` widgets are actually mounted in the widget tree (they were added but may not be in the right build path)
- Test if the issue is same-machine (loopback) -- WebRTC may not route audio when both peers are on localhost
- Check browser console for WebRTC errors (`chrome://webrtc-internals/` or Firefox `about:webrtc`)
- Verify ICE candidates are being exchanged (add logging to voice signal handler)
- Check if `getUserMedia` succeeds (microphone permission granted?)
- Test with two different machines on same network
- Check if TURN server credentials are valid and reachable
- Review `_attachRemoteAudioStream` -- is `renderer.srcObject` being set correctly?
- Consider: does `RTCVideoRenderer` actually play audio on web? May need `<audio>` HTML element instead

**Files:** `voice_rtc_provider.dart`, `chat_panel.dart` (RTCVideoView mounting), `ws/handler.rs` (signal relay)

### 2. Remove member from group doesn't work (#11, #17)
**Problem:** Clicking remove on a group member doesn't actually remove them. They stay in the group.

**Investigation plan:**
- Check `group_info_screen.dart` `_kickMember()` -- does it call the right endpoint?
- Check `DELETE /api/groups/{id}/members/{user_id}` in `routes/groups.rs` -- does it work?
- Check if the conversation list refreshes after removal
- Test: call the API directly via curl to confirm server-side works

**Files:** `group_info_screen.dart`, `routes/groups.rs`, `db/groups.rs`

---

## High (UX Bugs)

### 3. Settings cog vanishes when in a voice call
**Problem:** The settings gear icon disappears from the UI when connected to a voice channel.

**Fix:** The voice dock overlay may be covering the settings button. Check `home_screen.dart` voice dock positioning -- ensure it doesn't overlap the settings area. May need to adjust the dock's `bottom` offset or the settings button's z-index.

**Files:** `home_screen.dart`, `voice_dock.dart`, `user_status_bar.dart`

### 4. Leaving a call should deselect the lounge channel
**Problem:** After leaving a voice channel, the lounge chip stays selected/highlighted.

**Fix:** In `chat_panel.dart`, when `leaveVoiceChannel` succeeds, set `_activeVoiceChannelId = null`. Check if `setState` is called after leave.

**Files:** `chat_panel.dart`

### 5. Closing tab/app should leave the voice call
**Problem:** If user closes the browser tab or kills the app, they stay shown as "in call" for other users until stale session cleanup (5 min).

**Fix:**
- **Web:** Add `window.onbeforeunload` listener that calls leave endpoint
- **Desktop:** Add `WidgetsBindingObserver.didChangeAppLifecycleState` to detect app close and call `leaveChannel()`
- **Server:** The stale session cleanup (60s task) is the backup -- but the 5-min window is too long. Reduce to 2 minutes.

**Files:** `home_screen.dart` or `main.dart` (lifecycle), `voice_rtc_provider.dart`, `main.rs` (cleanup interval)

### 8. Read receipts not working correctly
**Problem:** Always shows double checkmarks regardless of read receipt toggle state. Should be: one check = sent/delivered, two checks = read. Only mark as "read" when recipient sends a message back.

**Investigation plan:**
- Check `message_item.dart` status icon rendering -- what determines single vs double check?
- Check `MessageStatus` enum -- is there a `read` status?
- Check if read receipts are actually being sent/received via WS
- Check privacy_provider `readReceiptsEnabled` -- is it consulted before sending read receipt?
- The "mark as read when they send a message" logic may need a design change

**Files:** `message_item.dart`, `websocket_provider.dart`, `chat_provider.dart`, `privacy_provider.dart`

### 9. Attachment button can be spam-clicked
**Problem:** Rapidly clicking the attachment/file picker button opens multiple file picker dialogs.

**Fix:** Add a `_isPickingFile` boolean guard. Set true before `FilePicker.platform.pickFiles()`, set false on completion/error. Disable button when true.

**Files:** `chat_panel.dart`

### 15. Copy image gives URL, not actual image to clipboard
**Problem:** Copying an image message puts the media URL in clipboard instead of the image data.

**Fix:** In the copy action for image messages, fetch the image bytes and put them in clipboard as image data. On web, use `Clipboard.write()` with a `ClipboardItem` containing the blob. On desktop, use platform-specific clipboard image write.

**Files:** `message_item.dart`

### 16. Videos not playable, images failing to load
**Problem:** Videos show play button but don't play. Images sometimes show "[Image failed to load]".

**Investigation plan:**
- Check if media ACL is blocking -- the sender can load but recipient can't?
- Check if `conversation_id` is being set on media upload (required for ACL)
- Test: can the uploader view their own media?
- For videos: check if the web player supports the video format (mp4 should work)
- Check CORS headers on media download endpoint

**Files:** `message_item.dart`, `routes/media.rs`, `chat_panel.dart` (upload)

### 23. Edit UI missing on long messages
**Problem:** When editing a very long message, the edit controls (save/cancel buttons) aren't visible.

**Fix:** Ensure the edit mode input area is scrollable or the buttons are always visible below the input. May need `SingleChildScrollView` wrapping or fixed-position buttons.

**Files:** `chat_panel.dart`

---

## Medium (UX Improvements)

### 6. No audio cues for voice connection/device testing
**Plan:** Add connection sounds:
- Play a short "connected" tone when joining voice channel
- Play a "disconnected" tone when leaving
- Add a "Test Microphone" button in voice settings that plays back your mic input for 3 seconds
- Show input level meter (animate a bar based on audio level)

**Files:** `voice_rtc_provider.dart`, `voice_settings_provider.dart`, `settings_screen.dart`, `assets/sounds/`

### 7. Hover message options too large/opaque, covers message
**Fix:** Reduce the hover action bar size and add transparency. Use `Opacity(opacity: 0.85)` and smaller icon sizes (16px instead of 20px). Or reposition to float above the message instead of overlapping.

**Files:** `message_item.dart`

### 10. Replace emoji+attach buttons with single + button
**Plan:** Remove the separate attachment and emoji buttons. Add a single `+` button on the left side of the input. On tap, show a small menu: "File", "Emoji". Tapping "File" opens file picker, tapping "Emoji" toggles emoji picker.

**Files:** `chat_panel.dart`

### 12. Allow messaging yourself (notes/bookmarks)
**Plan:**
- Server: Allow creating a DM conversation with yourself (currently may be blocked)
- Client: Add "Notes" or "Saved Messages" option in the new chat menu
- Messages to yourself skip encryption (no need to encrypt for self)

**Files:** `routes/messages.rs` (create_dm), `conversation_panel.dart` (new chat dialog)

### 18. Reaction picker above the button, not bottom bar
**Plan:** Change the reaction picker from a bottom sheet to a floating popup positioned above the reaction button (like iMessage/Telegram). Use `OverlayEntry` or `showMenu` positioned relative to the tap location.

**Files:** `message_item.dart`, `chat_panel.dart`

### 24. Discord-style left-aligned messages (appearance option)
**Plan:** Add a setting in Appearance: "Message layout" with options "Bubbles" (current) or "Compact" (Discord-style, all left-aligned with colored usernames). Store in SharedPreferences via theme_provider.

**Files:** `message_item.dart`, `settings_screen.dart`, `theme_provider.dart`

### 25. Ban vs kick distinction
**Plan:**
- Kick: removes from group, they can rejoin (current behavior)
- Ban: removes + adds to a `banned_members` table, prevents rejoin
- Server: Add `POST /api/groups/{id}/ban/{user_id}` endpoint
- Server: Check ban list in `join_group` handler
- Client: Add "Ban" option alongside "Remove" in member management

**Files:** `routes/groups.rs`, `db/groups.rs`, new migration, `group_info_screen.dart`

---

## Feature Requests

### 13. Animations are nice
Positive feedback -- keep the page transitions and sidebar animations.

### 14. Pretext integration (https://github.com/chenglou/pretext)
**Evaluation needed:** Pretext is a rich text editor. Could replace the plain `TextField` with a structured editor supporting:
- @mentions with inline rendering
- Markdown formatting
- Code blocks
- Emoji shortcodes

**Decision:** Evaluate if it has a Flutter/Dart port or if it's JS-only. If JS-only, would only work on web. For Flutter, consider `super_editor` or `fleather` packages instead.

### 19. Seed test groups with data
**Plan:** Create a script `scripts/seed_demo_data.sh` that:
- Creates an `admin_tester` account
- Creates 10 public groups with names/descriptions:
  - "Animal Lovers", "Meme Central", "Tech Talk", "Gaming Lounge", "Music Corner",
    "Art Gallery", "Movie Club", "Book Worms", "Fitness Crew", "Food & Recipes"
- Adds some sample messages in each
- Creates both text and voice channels per group

**Files:** New script `scripts/seed_demo_data.sh`

### 20. GIF search (like Discord/Teams)
**Plan:** Integrate Tenor or Giphy API:
- Add a GIF button in the compose area (or under the + menu)
- On tap: show a search panel with trending GIFs
- Type to search, show results in grid
- On tap GIF: send as `[img:tenor_url]` message
- Tenor API is free for non-commercial use (needs API key)

**Files:** New `gif_picker_widget.dart`, `chat_panel.dart`, server may need to proxy or allow external URLs

### 21. Desktop notifications + notification sounds
**Problem:** No notification sounds, no desktop notifications on Linux/Windows.

**Plan:**
- Notification sounds already exist (`assets/sounds/received.mp3`) -- check if `SoundService` is being called
- For desktop notifications: implement `notification_service_desktop.dart` using `flutter_local_notifications` package
- Show system notification when app is minimized/unfocused and a message arrives
- Check if muted conversations are correctly skipping notifications

**Files:** `notification_service.dart`, new `notification_service_desktop.dart`, `pubspec.yaml`

### 22. Proper Windows installer into userspace
**Problem:** Currently just running a portable exe, not installed into `%APPDATA%` or Program Files.

**Plan:** The Inno Setup installer (`Echo-Setup-x64.exe`) already installs to `{autopf}\Echo`. The issue may be that users are running the portable zip instead. Verify the installer works correctly and auto-update targets the installed version. Consider adding a "first run" dialog that offers to install if running from a non-standard location.

**Files:** `.github/workflows/release.yml` (Inno Setup config), `update_service_io.dart`

### 26. Seed groups with multiple channel types
**Plan:** Same as #19 -- the seed script should create groups with:
- `#general` text channel
- `#announcements` text channel
- `🔊 lounge` voice channel
- `🔊 gaming` voice channel

**Files:** `scripts/seed_demo_data.sh`

---

## Execution Order (Recommended)

### Batch 1: Critical fixes
1. Voice chat research + fix
2. Remove/kick member fix
3. Media loading (images/videos)
4. Read receipts

### Batch 2: High bugs
5. Attachment spam guard
6. Close tab leaves call
7. Settings cog in call
8. Lounge deselect on leave
9. Long message edit UI
10. Copy image to clipboard

### Batch 3: UX polish
11. Hover options opacity/size
12. + button consolidation
13. Reaction picker repositioning
14. Audio cues for voice

### Batch 4: Features
15. Self-messaging
16. Seed demo data script
17. GIF search
18. Desktop notifications
19. Discord-style layout option
20. Ban system
21. Pretext evaluation
