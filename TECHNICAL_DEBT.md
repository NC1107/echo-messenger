# Technical Debt — Echo Messenger

Open items from the **2026-05-29 voice-lounge focused audit** (5 parallel reviewers over the ~9.2k-LOC voice-lounge surface; full original findings were VL-1..VL-31). The critical + all high-severity findings plus a tranche of verified medium/low items shipped in **PR #1288**; what remains below is the open work, each re-verified against the actual code and deferred for a specific reason (a product call, an ops rollout, a larger refactor, or a dedicated test harness) rather than a guess.

Last updated: 2026-05-29.

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
