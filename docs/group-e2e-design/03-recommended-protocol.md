# 03 — Recommended Protocol

The picked option from [`02-protocol-options.md`](02-protocol-options.md), in implementation-ready detail. We call it **GRP2** to distinguish from the current `GRP1:` wire prefix.

## Crypto primitives

Identical to GRP1 plus per-message sender signatures.

| Primitive | Algorithm |
|-----------|-----------|
| Group symmetric key | 32-byte random, AES-256-GCM |
| Per-message nonce | 12-byte random |
| Envelope wrap | ECDH(X25519) → HKDF-SHA256 → AES-256-GCM (existing) |
| Sender signature | Ed25519 over `version_byte || nonce || ciphertext || tag || conversation_id || message_id_uuid` |

The signature is the only new primitive on the wire. It costs ~80 bytes per message and ~50 µs per send/verify — negligible.

## Wire format

```
GRP2:<base64( version(1) || nonce(12) || ciphertext || tag(16) || sender_sig(64) )>
```

Where `version=0x02`. The signature covers ciphertext + nonce + the server-side message ID (which the sender does not yet know) — so we sign the *content-defined* portion plus a UUID the sender mints locally and the server respects.

Compared to GRP1:
- `GRP2:` prefix instead of `GRP1:`.
- One leading version byte after the prefix (so we can grow to GRP2 v2 without a wire-format flag day).
- A 64-byte Ed25519 signature at the tail.

Receivers detect GRP2 by prefix, verify the signature against the from-user's identity key, then decrypt. A failed signature is a hard error — surfaces as `[Could not verify sender]`, not the same UX as `[Could not decrypt…]`.

## Key lifecycle

### Generation

- On group creation with `is_encrypted=true`: the creator generates the v1 group key and posts envelopes for all founding members.
- Server stores `(conversation_id, key_version, member_id, envelope)` rows.

### Active key version

- Each `is_encrypted=true` group has exactly one "active" version at any time, tracked server-side by `groups.active_key_version`. Senders fetch this to know which version to encrypt with.
- All previous versions are retained server-side. Receivers can decrypt at any retained version.

### Rotation triggers (any of)

1. Membership change (add or remove).
2. Admin clicks "Rotate group key" in the group settings.
3. Time-based rotation (30 days since last rotation).

### Rotation flow with deterministic leader election (closes #658)

The previous "first writer wins" race is replaced with a deterministic candidate ordering. All online members hear the trigger, but only one tries first.

1. Compute `leader = members[hash(group_id || trigger_event_id) mod len(members)]` where `members` is the current member list sorted by user ID. `trigger_event_id` is a UUID minted by the server on the triggering event so all clients agree on it.
2. If `self == leader`: start rotation immediately.
3. If `self != leader`: wait `1.5 s × rank` where `rank` is the position in the sorted ordering. Then check whether the new key version exists on the server; if yes, abort (someone else did it). If no, attempt rotation yourself.
4. The server-side `(conversation_id, key_version) UNIQUE` constraint is still the ultimate tie-breaker. Two clients colliding (e.g. on a network partition) still lose gracefully — one wins, the other gets 409 and re-fetches.

This is **PaxosLite-for-rotation**: pre-agreed candidate order makes "everyone immediately tries" no longer the failure mode. Liveness: as long as one online member completes the rotation, we're done. The trigger event is re-broadcast on rotation completion so straggler clients pick up the new version.

### Out-of-band recovery

- If after `members.length × 1.5 s` no rotation has been confirmed, *any* online member can self-elect by holding shift-clicking "Rotate group key" in settings. This is a manual escape valve — almost never needed, but available.

## Membership changes

### Add member

1. Admin posts `POST /api/groups/:id/members` (existing endpoint).
2. Server appends member, emits `member_added` event with `trigger_event_id`.
3. Rotation runs (closes the "new member shouldn't see history" property).
4. New member's first envelope is at the new key version.

### Remove member

1. Admin posts `DELETE /api/groups/:id/members/:user`.
2. Server marks member removed, emits `member_removed` event with `trigger_event_id`.
3. Rotation runs *excluding* the removed member (closes the "removed member shouldn't see future" property).
4. Server enforces that the removed member's envelope row is **not** written for the new version (server-side check, not client-side honour system).

## Per-message authenticity

The sender signature solves the "anyone with the group key can forge as anyone else" problem from [`02-protocol-options.md`](02-protocol-options.md). Recipients verify against the sender's Ed25519 identity public key, which they already have cached for 1:1 sessions.

Signature failures are *louder* than decryption failures. The placeholder text is different (`[Could not verify sender]` not `[Could not decrypt…]`) and the chat row is rendered with a danger-colored side stripe. This is intentional — a forged-signature event is more alarming than a normal decrypt failure and should not be confused with the "key out of sync" UX.

## Server-side enforcement (#591)

The server learns the *shape* of an encrypted message, never the content. On `is_encrypted=true` groups:

- Reject any send with content that does not start with `GRP1:` or `GRP2:`.
- Reject any send whose decoded base64 is shorter than the minimum valid GRP1/GRP2 payload.
- Reject any send whose `from_user_id` is not in the active member list.

These are cheap structural checks — no crypto on the server. They close the door on accidental plaintext leaks from buggy clients.

## What the design does *not* do

- No per-message forward secrecy at the group level (same trade-off as Signal's Sender Keys).
- No formal post-compromise security guarantee (rotation-based; cf. MLS).
- No anonymous group membership (server knows the member list — necessary for envelope routing).

These are intentional and called out in [`05-message-loss-analysis.md`](05-message-loss-analysis.md) and [`06-open-questions.md`](06-open-questions.md).
