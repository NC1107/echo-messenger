# Echo Messenger — Task Backlog

## Open Bugs

- [ ] **Web auth persistence** — Users get logged out on every page refresh. SharedPreferences/localStorage may not persist across reloads, or refresh tokens from before a DB reset are stale. Needs investigation of web-specific flutter_secure_storage behavior.
- [ ] **iOS push delivery in low-power mode** — APNs silent pushes are throttled by iOS in low power mode and when app is force-quit. Visible notifications now work but background wake is still best-effort. Consider adding a visible-only fallback when silent push fails.
- [ ] **Multi-device encryption sync** — Each device has its own identity key and sessions. Device B cannot decrypt messages that Device A encrypted. Signal solves this with "linked devices" (encrypt per-device). Current workaround: show one-time notice about message history on new devices.
- [ ] **Signed prekey rotation grace period** — If a peer fetches a bundle, then the signed prekey rotates and the grace period expires (21 days total), the peer's initial message will fail because neither current nor previous signed prekey matches. Consider extending grace period or syncing rotation with server.
- [ ] **Session corruption recovery UX** — Quarantined sessions have no user-visible recovery path. Users must manually reset encryption from the chat header menu. Consider showing a banner: "Encryption session needs repair — tap to fix."
- [ ] **Concurrent message decrypt interleaving** — Per-peer async locks are in place but the lock uses `Completer` which may not handle all edge cases. Verify under high message load.

## Open Features

- [ ] **Account recovery** — No password reset flow exists. Add optional email to accounts (server migration), password reset via email link, and future biometric unlock.
- [ ] **Unified "+" attachment menu** — Implemented on mobile. Desktop still uses the paperclip icon for file picker. Consider unifying the UX.
- [ ] **Global search improvements** — Basic search overlay implemented (Ctrl+Shift+F). Needs: highlight matched text in results, scroll-to-message on tap, search within a specific conversation.
- [ ] **Threads (Slack-style)** — Threaded replies within a conversation.
- [ ] **Polls** — Create and vote on polls in group chats.
- [ ] **Device/session tracking** — See active sessions and revoke them.
- [ ] **Mobile screen sharing** — Share screen in voice lounges from phone.
- [ ] **Account switching** — Multi-account support without logging out.
- [ ] **Biometric login** — Face ID / fingerprint unlock on mobile.

## Completed This Session

- [x] 7 crypto bugs fixed (OTP key collision, session persistence, history decryption, write-ahead saves, quarantine, fail-fast, session locks)
- [x] Device bundle fallback — server now picks newest device's bundle, not device 0
- [x] Image/avatar upload 401 retry with token refresh
- [x] Send confirmation timeout (15s → failed with retry)
- [x] Connection jitter + unlimited reconnect
- [x] Friendly encryption error messages (no raw exceptions)
- [x] iOS APNs push notifications (full implementation: server sender, iOS entitlements, AppDelegate, token registration)
- [x] Visible APNs push with sender name and message preview
- [x] iOS background persistence (UIBackgroundModes + delayed completion handler)
- [x] iOS notification grouping by conversation with subtitle
- [x] Splash screen timeout (5s) + faster startup (200ms)
- [x] Session replacement banner ("Signed in on another device")
- [x] Settings appearance centering (640px max-width)
- [x] Responsive breakpoint utility (`Responsive.isMobile/isDesktop`)
- [x] Mobile "+" attachment bottom sheet (Photos, Camera, Files)
- [x] Photos tab removed from emoji picker (moved to attachment menu)
- [x] Onboarding split into 4 pages (Welcome, Appearance, About You, Contacts)
- [x] Global search overlay (Ctrl+Shift+F + sidebar icon)
- [x] Protocol diagrams in README (Mermaid sequence + flowcharts)
- [x] Video quality defaults bumped (1.5Mbps/30fps, auto-quality enabled)
- [x] Swipe-to-reply gated to mobile only (no more desktop drag trigger)
- [x] Contacts info button removed (redundant — name tap opens profile)
- [x] Key reset peer notification (new WS event)
- [x] DM call notification (new WS event + push notification)
- [x] Send button disabled until crypto ready (DMs only)
- [x] DM conversation delete (new server endpoint + context menu)
- [x] Multi-device limitation notice (SnackBar on key regeneration)
- [x] Pending decrypt queue (messages arriving before crypto init are queued and decrypted when ready)
- [x] OTP fail-fast (V2 messages with missing OTP throw instead of silent 3-DH mismatch)
- [x] Peer identity cache cleared on key reset
- [x] iOS deployment target bumped to 26.0
- [x] ITSAppUsesNonExemptEncryption set in Info.plist
- [x] APNs env var docs + TestFlight setup guide
- [x] planned_features.md created
- [x] Playwright crypto DM test suite
