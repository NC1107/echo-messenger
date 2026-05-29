# Technical Debt — Echo Messenger

Open items from the **2026-05-29 voice-lounge focused audit** (5 parallel reviewers over the ~9.2k-LOC voice-lounge surface; full original findings were VL-1..VL-31). The critical + all high-severity findings plus a tranche of verified medium/low items shipped in **PR #1288**; what remains below is the open work, each re-verified against the actual code and deferred for a specific reason (a product call, an ops rollout, a larger refactor, or a dedicated test harness) rather than a guess.

Last updated: 2026-05-29.

> A second, broader tranche — the **2026-05-29 product-testing backlog** (~36 cross-platform items, each code-audited but not yet fixed) — is recorded in its own section at the bottom of this file: [2026-05-29 — broad product-testing backlog](#2026-05-29--broad-product-testing-backlog-audited-not-yet-fixed).

## Summary

**Open: 14** — 0 critical, 0 high, 8 medium, 6 low. None is a known crash; the crash-class findings all shipped in #1288.

| ID | Sev | Area | Why deferred |
|----|-----|------|--------------|
| VL-6 (residual) | med | canvas sync | needs server-assigned ordering |
| VL-8 (follow-up) | med | tests | needs a Room-injection seam |
| VL-14 | med | voice authz | product decision |
| VL-16 | med | canvas validation | ops rollout + media-authz analysis |
| VL-19 | med | multi-device | needs multi-device test harness |
| VL-15 | med | canvas authz | needs per-stroke author tracking |
| VL-29 | med | canvas perf | perf/hardening (rate-limited) |
| VL-28 | med | voice perf | perf (rate-limited) |
| VL-17 | low | canvas render | large architectural refactor |
| VL-21 | low | canvas gesture | conflicts with infinite-canvas intent |
| VL-23 | low | canvas sync | needs replace-board protocol |
| VL-24 | low | voice dos | LiveKit config / product |
| VL-26 | low | canvas sync | needs device-id in broadcast |
| VL-30 | low | canvas perf | pagination / streaming design |

---

## Residuals from shipped fixes

### VL-6 (residual) — cross-peer clear can still resurrect a stroke
**Shipped:** a remote `clear` now aborts the local in-flight stroke, closing the common same-device resurrection.
**Residual:** the cross-peer case — a stroke committed by peer B *before* B processed peer A's clear, arriving at A *after* A cleared — still re-appears on A. A full fence needs a server-assigned monotonic board-generation/sequence stamped on outbound strokes so inbound strokes predating the latest `clear` can be dropped.
**Effort:** medium (server + client protocol).

### VL-8 (follow-up) — LiveKit connection-lifecycle race is untested
**Shipped:** the real `handleCanvasEvent` ingress is now covered by `canvas_provider_hardening_test.dart`.
**Remaining:** `LiveKitVoiceNotifier.joinChannel` / `leaveChannel` / `_teardownCurrent` (the documented rejoin / dispose-during-connect race) have no execution test. Blocking dependency: there is no seam to inject a fake `Room` — the join sequence creates a real `Room` and touches mic permission / native LiveKit / CallKit. A `Room`-injection seam in `livekit_voice_provider.dart` must land first.
**Effort:** large.

---

## Medium — open

### VL-14 — LiveKit token grant is uniformly full-publish, 1h expiry, no post-kick eviction
**File:** `apps/server/src/routes/voice.rs:149`
**What:** every member (including listeners) gets `can_publish: true` with a fixed 1-hour expiry. A member removed seconds after minting retains SFU publish for up to an hour (LiveKit validates the JWT independently of the membership table).
**Why deferred:** needs a product decision (is there a listener-only role?) and the LiveKit server API for eviction on removal. Not a code-correctness fix.
**Fix:** role-scope grants, shorten `exp` to ~5–10 min with client refresh, evict via the LiveKit server API on member removal.
**Effort:** medium.

### VL-15 — `clear` event ignores `scope:"mine"` and always wipes the whole board
**File:** `apps/server/src/ws/events/canvas.rs` (`clear` → `clear_all`); validator accepts `"mine"` in `canvas_validation.rs`
**What:** the validator accepts `scope:"mine"` but `persist_canvas_state` always routes `clear` to `clear_all`. (Clear-all by any member is documented intent; the client's "clear mine" uses `importSnapshot`, not this scope — so no current client actually sends `"mine"`.)
**Why deferred:** real per-user clear needs per-stroke author tracking (a schema/data-model change). The only quick change — dropping `"mine"` from the validator — is a marginal wire-contract tweak with its own risk.
**Fix:** add author id to stored strokes/images and branch `clear` on scope; or remove `"mine"` from the validator so the contract is honest.
**Effort:** medium–large.

### VL-16 — geometry validation ships non-blocking (`LogOnly`) + `image_add` URL not ownership-checked
**File:** `apps/server/src/ws/events/canvas.rs` (`CANVAS_VALIDATION_MODE` default `LogOnly`); `validate_image_url`
**What:** in the default `LogOnly` mode the PR #1269 geometry validator logs but does not drop malformed payloads, so they still persist + fan out. Separately, `validate_image_url` only checks the `/api/media/` prefix, not that the media belongs to this conversation.
**Why deferred:** flipping the default to `Enforce` is an **ops** rollout decision gated on the documented soak window, not a code change — enabling enforcement is a behavior change that needs deliberate timing. The URL-ownership half needs a media-authz analysis (is media already access-controlled at fetch time?).
**Fix:** flip default to `Enforce` once soak elapses; add a conversation-ownership check to `image_add` URLs.
**Effort:** small (flag) / medium (ownership check).

### VL-19 — server excludes by user-id, not device-id → a user's 2nd device never sees the 1st's strokes
**File:** `apps/server/src/ws/events/canvas.rs:339` (`broadcast_json(..., Some(sender_id))`)
**What:** canvas strokes are relayed excluding the sender's user UUID, so *all* of that user's connections are excluded; a read-only second device never receives the authority device's strokes — contradicting the multi-device read-only-viewer intent (`docs/voice-lounge/03-multi-device.md`).
**Why deferred:** the fix (use `None` + rely on the new VL-4 receive-dedup) is now plausible, but it changes broadcast semantics for ALL canvas kinds and interacts with `stroke_partial` self-echo. Needs validation on a real two-device setup.
**Fix:** exclude by device/connection id, or broadcast to all + client-side own-echo dedup; verify with a multi-device test harness.
**Effort:** medium.

### VL-28 — voice-signal relay performs 5 sequential DB round-trips per frame
**File:** `apps/server/src/ws/events/voice.rs:49-132`
**What:** every `VoiceSignal` frame (offers/answers/ICE — tens per peer per negotiation) issues five separate awaited queries (`is_member`, `get_conversation_kind`, `get_channel`, two `is_user_in_voice_channel`). Bounded by the global 3 msg/s WS limit, but multiplied across a large call the aggregate query count is high.
**Why deferred:** perf optimization, rate-limited, non-crash; the query-collapse must preserve exact authz semantics.
**Fix:** collapse into one JOINed query; cache the effectively-static conversation/channel kind.
**Effort:** medium.

### VL-29 — `update_image` rewrites the full client object on every move
**File:** `apps/server/src/db/canvas.rs:212`
**What:** `add_image` enforces `MAX_IMAGES`, but `update_image` (image_move) rewrites the matching image object with the full client-supplied payload (≤16 KB) via a whole-array JSONB rewrite per move, with no field projection.
**Why deferred:** perf/hardening, bounded by the 16 KB frame cap + 3 msg/s rate limit, non-crash.
**Fix:** server-side projection to position/size fields only; reject unknown fields in enforce mode; consider a normalized images table.
**Effort:** medium.

---

## Low — open

### VL-17 — live eraser preview is a no-op
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_strokes.dart` (active-stroke painter)
**What:** the active stroke lives on L2 (a separate `RepaintBoundary` above committed L1); `BlendMode.dstOut` inside L2's own `saveLayer` only clears L2's empty raster, so dragging the eraser shows nothing erasing until pointer-up commits it into L1.
**Why deferred:** large architectural — destructive blends fundamentally can't preview across the layer split.
**Fix:** composite the eraser preview against the committed layer, or preview it as a translucent stroke; needs a rethink of the 3-layer model.
**Effort:** large.

### VL-21 — pan transform is never clamped
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_gestures.dart` (`_applyPanDelta`)
**What:** pan adds raw deltas with no clamp against the 100k surface; with `minScale=0.2` the surface can be panned entirely out of view, recoverable only via the reset-view button.
**Why deferred:** conflicts with the documented Miro-style infinite-canvas intent (project memory: ~100k×100k, no zoom floor); the reset-view button is the intended recovery. Whether to clamp is a UX decision, not a clear bug.
**Fix (if pursued):** clamp post-pan translation so a margin of content/surface stays in view.
**Effort:** medium.

### VL-23 — `importSnapshot` / `clearMyDrawings` can silently truncate at the server cap
**File:** `apps/client/lib/src/providers/canvas_provider.dart` (`importSnapshot`)
**What:** these fire a burst of per-stroke WS events; a large import hits the server stroke cap mid-stream and silently truncates peers' boards with no error surfaced to the importer.
**Why deferred:** needs an atomic "replace board" event or chunked acks (protocol work).
**Fix:** server atomic replace-board, or chunk + await acks and surface the cap-reached error.
**Effort:** medium.

### VL-24 — no per-user LiveKit participant cap
**File:** `apps/server/src/routes/voice.rs:92`
**What:** the nonce-identity rejoin fix (PR #1235) is sound, but nothing caps distinct identities per user — scripted token requests could mint many publishing participants into one room.
**Why deferred:** LiveKit room config / product.
**Fix:** set room `maxParticipants` and/or evict prior same-user participants on new-token issuance; track issuance rate.
**Effort:** medium.

### VL-26 — partial-stroke placeholder keyed by user-id only
**File:** `apps/client/lib/src/providers/canvas_provider.dart` (`partial_<userId>_in_progress`)
**What:** the in-progress placeholder id derives solely from `fromUserId`, so two devices of one user drawing concurrently would interleave into one garbled placeholder.
**Why deferred:** largely mitigated already by VL-20 single-writer authority gating; a full fix needs a `from_device_id` in the server broadcast payload (which currently carries only `from_user_id`).
**Fix:** add `from_device_id` to the broadcast and key the placeholder on `(userId, deviceId)`.
**Effort:** small (once the server payload carries device id).

### VL-30 — `get_canvas` returns the entire board unpaginated
**File:** `apps/server/src/routes/canvas.rs:56`
**What:** every lounge join loads the full `drawing_data` + `images_data` (up to ~32 MB at the cap) in one unpaginated JSON response, decoded fully into memory server-side.
**Why deferred:** large/design.
**Fix:** paginate/chunk the stroke/image arrays (cursor by index) or gzip; consider lowering the per-stroke point cap.
**Effort:** medium.

---

*Items resolved in PR #1288 (VL-1..VL-5, VL-7, VL-9..VL-13, VL-18, VL-20, VL-22, VL-27, VL-31) and the non-issues (VL-7 pinch re-seed, VL-25 fullscreen/view-mode) are recorded in that PR and its commits; they are intentionally omitted here so this file tracks only open work.*

---

# 2026-05-29 — broad product-testing backlog (audited, not yet fixed)

~36 items from a live cross-platform testing pass. Each was validated by a **read-only code audit** (does it reproduce in the code? where? root cause?) and recorded here **before** any fix lands, per the working rule. Verdict legend: **BUG** = real defect; **GAP** = feature not built; **BY-DESIGN** = current behaviour is intentional (UX call to change it); **REPRO?** = code looks correct, needs a live repro to confirm. IDs reference [[project-backlog-may29-full]] in project memory.

## Summary

| ID | Area | Verdict | Sev | Effort | Root cause (file) |
|----|------|---------|-----|--------|-------------------|
| 1 | composer | BUG | med | S | slash select no haptic — `input/slash_command_autocomplete.dart:92` |
| 2 | composer | REPRO? | — | — | autoscroll IS wired — `chat_panel.dart:1020` (`onMessageSent`→`_scrollToBottom`) |
| 3 | composer | BY-DESIGN | low | M | one cmd/msg by parser design — `services/slash_commands.dart` |
| 4 | composer | GAP | med | M | no `/gif` in registry — `services/slash_commands.dart` |
| 5 | composer | BUG | high | M | body uses `RichText`, not selectable — `message/rich_text_content.dart` |
| 6 | composer | BUG | low | S | typing bubble opaque/large — `typing_bubble.dart:57` |
| 7 | markdown | BUG | med | M | no `***bold-italic***` pattern — `message/markdown_patterns.dart:15` |
| 8 | composer | BUG | high | S–M | URL not stripped when embed card shows — `message_item.dart:851` |
| 9 | media | GAP | med | M–L | one media/msg, multi sent separately — `message/media_content.dart:336`, `chat_input_bar/parts/send_handling.dart:101` |
| 10 | media | BUG | med | M | multi-select sends immediately, no staging — `chat_input_bar/file_pickers.dart:202` |
| 11 | media | REPRO?/BUG | high | L–M | sender sees own video, peers can't (Linux) — media URL resolve `message/media_content.dart:82`; needs logging |
| 12 | media | BUG | high | M–L | inline player hardcodes 16:9, ignores rotation — `message/video_player.dart:134` |
| 13 | media | BUG | med | M | images not size-reserved → reflow/jump — `chat_panel/chat_message_list.dart:249` (`addAutomaticKeepAlives:false`), `message/image_attachment.dart:90` |
| 14 | threads | BY-DESIGN | med | M | mobile thread = draggable sheet, rough — `thread_view_panel.dart:845` |
| 15 | threads | BY-DESIGN | low–med | M | mobile thread layout cramped/modal — `thread_view_panel.dart:545` |
| 16 | perms | BUG | high | S | pin-error toast behind keyboard — `services/toast_service.dart:164` (`bottom:24` ignores `viewInsets`) |
| 17 | perms | GAP | med | M | no per-group role-change endpoint or UI — `routes/groups/members.rs`, `group_info_screen/parts/members_section.dart` |
| 18 | calls | GAP | low–med | M | no call_history/duration persisted — only "Voice call started" sys event |
| 19 | theme | BUG | high | S | Ember reply quote uses dark `onPrimary` on amber bubble — `message/reply_quote.dart:93`, `theme/echo_theme.dart:343,613` |
| 20 | canvas | BUG | high | M | Android draw blocked / wrong-writer — authority desync on reconnect (stale cached device authority); `providers/canvas_provider.dart:1179`, `ws/events/canvas_authority.rs` |
| 21 | canvas | BUG | high(mobile) | S | minimap re-centres every `onPanUpdate` → over-sensitive — `widgets/voice_lounge/canvas_minimap.dart:68` |
| 22 | canvas | BUG/VERIFY | high | M | avatars not movable in post-rewrite lounge — drag exists in `widgets/voice_canvas.dart:974` but verify it's wired into `voice_lounge_screen`; also no authority gate on `moveAvatar` (`canvas_provider.dart:692`) |
| 23 | canvas | PENDING AUDIT | ? | ? | "screenshare not appearing on canvas" — not yet validated; likely tied to screenshare rendering in viewport-space outside the canvas transform |
| 24 | canvas | PARTIAL | med | M | images/screenshare not resizable (avatars have a resize ring) — `widgets/voice_canvas.dart:1037`, `voice_lounge/screen_share.dart` |
| 25 | canvas | BUG | med | S | PNG export OOM/`invalid arguments` on Android — `toImage(pixelRatio:2.0)`×6000 board exceeds GPU tex limit — `services/canvas_export_service.dart:35` |
| 26 | canvas | BUG | med | M | image-adder doesn't see own image — server excludes sender from broadcast (relates to VL-19) — `ws/events/canvas.rs:343`; needs self-render or own-echo |
| 27 | canvas | GAP | low | M | only URL paste, no binary image paste — `widgets/voice_canvas.dart:_handlePasteImage` (helpers exist: `utils/clipboard_image_helper*.dart`) |
| 28 | canvas | BY-DESIGN | low–med | S | switching back to canvas keeps last pose, doesn't recenter — `voice_lounge_screen.dart:1599` (recenter only on first mount) |
| 29 | canvas | BUG | high | M | `_clampTransform` centres when zoomed-out → "invisible wall" — `widgets/voice_lounge/lounge_canvas_gestures.dart:488` |
| 30 | canvas | BUG(race) | low–med | M–H | can escape bounds on mobile via multi-touch race (all paths call clamp; pinch/pan seed race) — `lounge_canvas_gestures.dart:372` |
| 31 | voice | BUG | med | S | Android bg audio can suspend — foreground service lacks `AudioManager` audio-focus (USAGE_VOICE_COMMUNICATION) — `android/.../EchoForegroundService.kt:72` |
| 32 | voice | REPRO? | low | — | bottom bars guarded mutually-exclusive (`narrow_layout.dart:249` `!_showingLounge`); "doubled" likely transient on swipe |
| US | search | PARTIAL/MOSTLY-DONE | low | S–M | global search ALREADY returns users+groups via `/api/search` — `widgets/global_search_overlay.dart:208`; only gap is *discoverable public* groups + join affordance |
| AV | sidebar | NEEDS-LOCATING | ? | ? | bottom-left self-avatar not found in `desktop_layout.dart`; check sidebar account row / status pill (memory [[feedback_status_surfacing]]) then fix provider-watch/cache-bust |
| GIF | media | BUG | med | S | GIF re-decodes smaller when unfocused — `providers/gif_playback_provider.dart:38` pauses on `AppLifecycleState`; decouple focus from playback |
| SQ | voice | GAP (approved) | med | M | video bitrate caps ~1.5 Mbps — `livekit_voice_provider.dart:99`; add presets to ~5 Mbps + quality indicator |
| NAV | nav | GAP (approved) | low | M | no conversation history stack — `home_screen.dart:86` single ref; add stack + title-bar back/forward (`window_chrome.dart`) |
| TASKBAR | layout | PENDING AUDIT | ? | ? | "screens render over the OS taskbar" — not yet validated; find the fullscreen screen(s) / `SystemChrome` usage |

## Notable corrections from the audit (before building)

- **#2 / #32 are likely non-issues** in the code (autoscroll-on-send and the mobile double-bar are both already handled/guarded) — get a fresh repro before spending effort.
- **#US is mostly already built** — `/api/search` already returns contacts + groups and the overlay renders them; the real remaining work is *public/discoverable* groups + a join affordance, not a from-scratch feature. (Supersedes the earlier "expand universal search" scoping.)
- **#3 (chaining slash commands)** matches Discord/Slack convention (one per message) — recommend won't-fix unless a delimiter syntax is desired.
- **#22/#24 hinge on whether `widgets/voice_canvas.dart` is still wired** post-canvas-rewrite (#1278); confirm the active avatar/image layer before estimating.
- **#20 and #26 both touch the canvas sender-identity / echo model** and relate to open **VL-19** (broadcast excludes by user-id) — fix them together.

## Suggested fix order (when work resumes)

1. **Cheap, high-impact BUGs:** #16 pin-toast (`viewInsets`), #19 Ember reply colour, #8 embed double-text, #6 typing bubble, #1 slash haptic, #21 minimap sensitivity, #25 PNG export clamp.
2. **Medium UX BUGs:** #5 selectable message text, #13 image size-reservation (also explains #2/"jumping"), #12 vertical video, #29 canvas pan clamp, #31 Android audio-focus, #GIF focus re-decode.
3. **Feature gaps (scoped):** #10 staged multi-photo, #9 gallery, #SQ bitrate presets, #17 promote-to-admin, #4 `/gif`, #US public-group search, #18 call history, #NAV nav arrows, #27 canvas image paste.
4. **Needs repro/verify first:** #2, #32, #11, #22, #23 (screenshare), #TASKBAR, #30.

## Third tranche (N1–N9, audited 2026-05-29)

A follow-on testing batch, same audit method. **N4, N6, N8 are confirmed HIGH-severity bugs** and should jump the queue.

| ID | Area | Verdict | Sev | Effort | Root cause (file:line) |
|----|------|---------|-----|--------|------------------------|
| N1 | theme | BUG | med | M | hardcoded `Colors.white` / black shadows break non-default themes — `thread_view_panel.dart:807,916`, `message_item.dart:1811,1834` |
| N2 | threads | GAP | low | M | thread panel fixed `width:380`, no drag-resize — `thread_view_panel.dart:272` |
| N3 | chat | GAP | low | S | no persistent jump-to-bottom FAB (only a "new messages" banner) — `chat_panel.dart:152` |
| N4 | sync | **BUG** | **high** | M | group `new_message` fanout filters out the whole `sender_id`, so the sender's OTHER devices never get the live event — `ws/message_service/fanout.rs:394` |
| N5 | nav | REPRO? | med | M | channel-column swipe (Android) may lose the gesture arena — `mobile_channel_drawer.dart`; needs repro |
| N6 | settings | **BUG/CRASH** | **high** | S | mobile Voice&Video settings crash — `enumerateDevices()` called from build without guard — `settings/voice_section.dart:237,357` |
| N7 | chat | BUG | med | S | swipe-to-reply wraps only the bubble; tiny bubbles = tiny target — `message_item.dart:1748` |
| N8 | chat | **BUG** | **high** | M | switching text channels doesn't scroll to bottom (only `conversation.id` change triggers it) — `chat_panel.dart:191` |
| N9 | media | GAP/BUG | med | M | Linux video playback (libmpv codecs / auth headers / relative URL) — `message/video_player.dart:79`; overlaps #11 |

Notes:
- **N4 is the same bug class as VL-19 and #26** (server excludes by user-id, not device-id). A single "deliver to sender's other devices" fix (mirroring the existing `deliver_self_messages` path with a `new_message` frame) covers the group-sync case; fix alongside VL-19/#26.
- **N6** is the only crash in this tranche — move `_loadAudioDevices()` to `initState` with a try/catch that sets a loaded flag even on failure.
- **N8** likely also explains part of #2/"jumping" perception when switching channels.
- N2/N3 are GAPs (not bugs) but cheap; N3 (jump-to-bottom FAB) directly answers the user's "add a way to jump to latest" ask.
