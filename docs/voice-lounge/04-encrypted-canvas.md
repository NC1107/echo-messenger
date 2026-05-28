# 04 — Encrypted-group canvas

## Status quo

**Canvas events are plaintext on the wire and on disk, regardless of whether the lounge belongs to an encrypted group.**

Citations:
- `apps/server/src/ws/events/canvas.rs:137` — `handle_canvas_event` takes JWT-authenticated `sender_id`, calls `verify_membership(sender_id, conversation_id)`, then accepts the payload. No encryption check, no per-event signing.
- `apps/server/src/db/canvas.rs` — persistent kinds (`stroke`, `image_add`, `image_move`, `image_remove`, `clear`) are written to the database as JSON. Server reads them on join to send the current board state to new arrivals.
- `apps/client/lib/src/providers/canvas_provider.dart` — sender does not consult `is_encrypted` on the group; the payload goes through `_sendCanvasEvent` regardless.

This means: in an encrypted group, where 1:1 and group **messages** are E2E encrypted (per #1131 / GRP2 design), canvas content is still **server-readable**.

This is a real privacy gap. Today it is undocumented. `docs/PRIVACY.md` does not call it out.

## Why this is the way it is

Canvas was added before GRP2 message E2E was specified. The fast path was "WS relay using existing JWT auth"; that worked for plaintext groups (where messages also go plaintext via the relay) and was never revisited when GRP2 was scoped. GRP2 design (`docs/group-e2e-design/`) targets **messages** specifically — canvas isn't in its scope.

## Options

### Option A — Accept the gap; document it explicitly

Update `docs/PRIVACY.md` to call out:
- Canvas drawings, screen-share window positions, and avatar positions are **not** E2E encrypted, even in groups where messages are.
- Treat canvas content as visible to the server operator (us, today; the self-hoster when self-hosted).

Keep behavior unchanged.

- **Pro:** zero engineering work. Honest privacy posture.
- **Con:** users in encrypted groups may incorrectly assume "encrypted" applies to the whole lounge experience. Privacy debt grows the longer it stays.

### Option B — Encrypt canvas payloads with the group's GRP2 sender key (when GRP2 ships)

Once GRP2's sender-key infrastructure is live for messages, reuse the same per-group symmetric key to encrypt canvas event payloads. Server still relays + persists, but the payloads it sees are ciphertext blobs.

- **Pro:** matches the message-encryption posture; no separate trust model.
- **Con:** depends on GRP2 message E2E landing first. The canvas DB schema needs to accept opaque blobs (it does — JSON columns can hold ciphertext-strings, but server-side replay-from-snapshot semantics change because the server can't introspect). Persisted strokes for late joiners need to be re-encrypted on every key rotation, which is non-trivial state to manage.

### Option C — Disable canvas in encrypted groups until Option B ships

Flip canvas off in `is_encrypted == true` groups. Plaintext groups keep the feature.

- **Pro:** closes the gap immediately. No trust mismatch.
- **Con:** removes a feature from the group type that's about to become the default (#1131 flipped new groups to encrypted-by-default). Users would lose access to the lounge canvas in most of their groups.

## Decision

**Option A short-term, Option B medium-term.** Dated 2026-05-28.

Short-term action (this Phase 1 PR's scope, or a fast follow-up):
- Add a `Canvas content is not encrypted` section to `docs/PRIVACY.md`.
- Add a non-blocking notice in the lounge UI for encrypted groups: a small text under the lounge header like "Canvas drawings and shared positions are visible to the server." Dismissible-per-lounge but reappears on each new lounge.

Medium-term action (scheduled after GRP2 message E2E lands):
- Tracked as #1268 (filed 2026-05-28), linked to the GRP2 design and this doc.
- Acceptance: server logs no longer contain plaintext canvas payloads in `is_encrypted == true` groups.

Option C is rejected because the feature is too useful to remove and the gap is small enough to disclose-and-defer.

## Acceptance criteria

- `docs/PRIVACY.md` contains a section titled "Voice-lounge canvas" that states canvas data is server-readable.
- An encrypted-group lounge displays a one-line privacy notice on first entry.
- A tracked follow-up issue exists for the GRP2-canvas-encryption work with the documented pickup trigger: "GRP2 message E2E shipped to prod (not just merged)."
- No PR that adds new canvas event kinds may merge without explicitly stating which side (plaintext or encrypted) it lives on. If plaintext, the PR must also add the kind to the privacy-doc list.

## Open questions

- **Server-side metadata even after Option B** — group_id, sender_user_id, timestamp, and event_kind remain visible to the server post-Option-B. That's the metadata floor for any relay-based architecture. Open question for a future doc: do we want a P2P-mesh alternative for canvas that hides metadata too? Unlikely in this product but worth naming.
- **Existing persisted plaintext strokes after Option B lands** — when GRP2 encryption gets retrofitted to canvas, what happens to drawings already in the DB? Three options: leave them plaintext and let them age out; encrypt-in-place during a one-shot migration; just drop them at cutover. Pickup: during Option B implementation, decide based on how many groups have meaningful canvas content at that time.
- **Image uploads** — `image_add` events reference media URLs that resolve to files in `./uploads/`. Even with payload encryption (Option B), the image bytes themselves are stored unencrypted. Closing that gap is its own design (likely requires per-group media keys + ciphertext-at-rest, which the existing media pipeline doesn't do). Pickup: same trigger as Option B.
