# 03 — Multi-device per user

## Status quo

Canvas avatar entries are keyed by `user_id`, **not** by `(user_id, device_id)`. Every device for a user shares one avatar slot.

Citations:
- `voice_canvas.dart:341` — `key: ValueKey('avatar-${participant.userId}')`
- `voice_canvas.dart:353` — `.moveAvatar(participant.userId, norm)`
- `canvas_provider.dart:534` — `void moveAvatar(String userId, CanvasPoint pos)`
- `canvas_provider.dart:868-870` — incoming `avatar_move` payload keyed by `userId`

### What happens today with two devices

A user on desktop + phone simultaneously in the same lounge:

1. Both devices receive `lounge.join` and add the user's avatar.
2. Each device computes its own `_defaultAvatarPos` from its local view of `total participants + index`. Because the same user appears once in the participant list (server dedupes by user_id), the position calculation is consistent.
3. Either device can drag the avatar. The drag broadcasts `avatar_move` with the user_id. Both devices apply it — including the device that **didn't** initiate it.
4. If both devices drag simultaneously, the two `avatar_move` streams interleave at the server; the receiving canvas state is last-write-wins. The user's avatar visibly fights itself.
5. Both devices show the same single avatar, even though there are two real call participants associated with this user_id.

### The interactions this breaks

- Simultaneous edits from two of the user's own devices cause avatar jitter.
- Other participants can't visually distinguish "Nick on desktop" from "Nick on phone" — relevant for voice attribution if one device is muted and the other isn't.
- A user joining their second device gets dropped into a position calculated as if they were one participant; the avatar position is shared and nothing new gets placed.

This is a latent bug. It hasn't surfaced as a user report yet because multi-device-in-the-same-call is rare in beta.

## Options

### Option A — Keep user_id keying; accept LWW

No change. Document the limitation. Two devices fight; users learn to use one device per call.

- **Pro:** zero work.
- **Con:** real LWW jitter when a user actually uses two devices. Doesn't scale with adoption.

### Option B — Switch to (user_id, device_id) keying

Each device gets its own avatar slot. Display name shows `username` for the first one and `username (device 2)` for the second.

- **Pro:** clean model; matches the underlying reality.
- **Con:** confusing — most users don't think of themselves as multiple avatars. Two avatars with the same picture and name might look broken. Also requires server-side multi-device coordination (each device needs a unique session id that survives reconnects).

### Option C — Single avatar slot per user; one device is the "canvas authority"

User_id keying stays. When a user has 2+ devices in a lounge, the **most-recently-active** device is the only one allowed to send canvas events for that user. Other devices are read-only on canvas (they still see and render, just can't send `avatar_move` / `stroke` / `image_*`).

The "most-recently-active" device is whichever sent the most recent canvas event from this user_id, with a fallback rule of "first to join the lounge" on cold start.

- **Pro:** fixes the LWW bug without introducing duplicate-avatar UX. Failure mode (a tester's old device sometimes can't draw) is recoverable by tapping the canvas on the device they want to use.
- **Con:** silent — a user dragging on phone while desktop is "canvas authority" sees no effect and might think the canvas is broken. Needs a small UI indicator ("Drawing from desktop") to make the state visible.

## Decision

**Option C**, dated 2026-05-28.

Single avatar slot per user. The most-recently-active device is the canvas authority. Other devices are read-only and show a small "Drawing from <device name>" pill in the canvas top-bar so the user understands why their input is ignored. Tapping the canvas on a non-authority device sends a `canvas_authority_claim` event that flips authority to that device after a 1s grace period (the grace stops mash-tapping causing rapid handoff oscillation).

Server-side: `canvas_authority_claim` is a new event kind alongside `avatar_move`. The server tracks `(user_id, voice_channel_id) → device_id` in memory (no DB persistence — the state resets when the user leaves the lounge). All `avatar_move` / `stroke` / `image_*` events from a non-authority device are silently dropped at the server with no error response (drop-not-reject so the rogue device doesn't repeatedly retry).

This is **not** a multi-device E2E protocol change — it's a single-writer-per-lounge policy on top of existing infrastructure.

## Acceptance criteria

- Two devices for the same user join the same lounge. Only one device's gestures move the avatar.
- The non-authority device displays an indicator naming the authority device.
- Tapping the canvas on the non-authority device transfers authority within 1-2 seconds.
- A user with one device sees no behavioral change from today.
- A user joining their second device sees their existing avatar, not a duplicate.

## Open questions

- **Device-name display** — how do we surface the device name? `device_name` is collected during key upload (per the device-aware server work). Need to confirm it propagates into the lounge presence payload. Pickup: during implementation, if not present, decide between adding to presence vs. inline lookup via `/api/devices/<id>`.
- **Cross-lounge authority** — does the authority device for lounge A automatically also become authority for lounge B if the user joins B? Default answer: no, authority is per-lounge. Open to revisit if testers find that confusing.
- **Voice-attribution UX** — currently muting on one device doesn't visually distinguish which device is muted on the avatar. That's a voice-system issue, not a canvas one, and is out of scope here. Captured for future routing to the voice surface.
