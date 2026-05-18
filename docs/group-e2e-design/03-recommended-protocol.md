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
- One leading version byte after the prefix (so we can grow to subsequent GRP2 revisions without a wire-format flag day).
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

### Rotation flow with server-led leader election (closes #658)

*(Revised after the security + backend review. Earlier drafts proposed a client-side `hash(group_id || trigger_event_id) mod N` scheme; both specialists pushed back because (a) client-side membership-list disagreement during a partition can produce different elected leaders across clients, and (b) the deterministic-leader framing oversold what is actually "UNIQUE constraint + randomised jitter". This version moves election to the server, where the authoritative member list and online-status registry already live.)*

The server is the only component that always sees every membership change in causal order and always knows which members are currently online via the WebSocket hub (DashMap of `user_id → sender`). It is the right component to pick the leader.

**Server side** — when emitting a rotation trigger event (membership change OR `POST /api/group-keys/:conversation_id/rotate`):

1. Snapshot the current member list **and** the online set from the WS hub.
2. Pick `leader = lowest user_id among online members` (deterministic, no consensus needed). If no member is online, defer the trigger and re-emit on the next member's reconnect.
3. Compute a `fallback_order` = remaining online members sorted by user_id ascending.
4. Emit `group_key_rotation_requested { trigger_event_id, conversation_id, leader_user_id, fallback_order: [u2, u3, ...], deadline_ms: 7500 }` to all online members.

**Client side**:

1. Receive the event.
2. If `self.user_id == leader_user_id`: start rotation immediately.
3. Otherwise: wait `deadline_ms` (7.5 s default). On expiry, check whether a new key version has appeared on the server; if yes, abort. If no, walk `fallback_order` — the client at position 0 attempts, then waits another `deadline_ms`, then the client at position 1 attempts, etc.
4. The server-side `(conversation_id, key_version) UNIQUE` constraint remains the **actual safety**. If two clients race (split-brain, recoverable error, retried trigger event), one wins and the other gets HTTP 409 and re-fetches the active version.

**What this design honestly does and does not promise**:

- ✅ Liveness when *any* online member can complete a rotation. The leader is an optimisation that reduces 409 traffic and stampedes, not a consensus protocol.
- ✅ Safety from concurrent rotations is owned by the database UNIQUE constraint, not by the election. The election makes the happy path quiet; the constraint makes the bad path correct.
- ❌ This is not PaxosLite. It is "server picks first candidate; UNIQUE catches races." Earlier doc framing was sloppy.
- ❌ It does not guarantee progress when *no* member is online. The trigger is re-emitted on next reconnect.

### Out-of-band recovery

- Manual escape valve: any group admin can re-trigger a rotation from settings. This goes through the same flow above; the server elects a leader again.
- If a partition leaves part of the group permanently disconnected from the server, that subgroup obviously cannot complete a rotation. There is no design fix for this — it is a property of "we have a server".

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

The sender signature closes the "anyone with the group key can forge as anyone else" attack from [`02-protocol-options.md`](02-protocol-options.md). Recipients verify against the sender's Ed25519 identity public key, which they already have cached for 1:1 sessions.

Honest framing: this only holds *as long as the sender's identity key has not itself been compromised*. A compromised-then-removed member who still has both their identity key and the v_N-1 group key can produce signed ciphertext attributed to themselves. This is unavoidable without forward-secure identity keys (out of scope). What the signature does buy is preventing a *different* member from forging as someone they aren't.

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
