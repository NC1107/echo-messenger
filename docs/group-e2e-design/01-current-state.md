# 01 — Current State of Group Encryption

What is shipped today, what is half-wired, what is missing. Sources: `apps/client/lib/src/services/group_crypto_service.dart`, `apps/server/src/routes/group_keys.rs`, `apps/client/lib/src/services/crypto_service.dart`.

## What works

### Group key generation + envelope wrapping

- `GroupCryptoService.generateGroupKey()` produces a random 32-byte AES-256 key.
- `getGroupKey(conversationId)` returns the active key from in-memory cache (5-minute bundle TTL on the network fetch).
- Per-member envelopes: the group key is ECDH-encrypted under each member's X25519 identity public key. Server stores `(group_id, member_id, key_version, envelope_bytes)` rows.
- AES-256-GCM with random 12-byte nonce. Wire format prefix: `GRP1:` followed by base64 of `nonce(12) || ciphertext || tag(16)`.

### Send path (when `is_encrypted=true`)

- `sendGroupMessage` calls `groupCrypto.getGroupKey(conversationId)`. If a key is in cache or fetched from server, encrypt and send.
- **If no key is available, the send hard-fails** (CLAUDE.md #344): the message bubble is added in a "failed" state with placeholder text. It is *not* silently sent in plaintext.

### Server-side rotation race guard

- `routes/group_keys.rs` enforces `(conversation_id, key_version) UNIQUE` at the database layer. First writer wins; a second concurrent writer gets HTTP 409 and retries.

### Rotation trigger

- `crypto_provider.rotateGroupKey()` is called on `group_key_rotation_requested` events (membership change, manual rotation).
- The rotator regenerates a key, wraps it for the remaining members, posts envelopes.
- Old key version remains decryptable for historical messages (versioned keys; server stores all versions).

## What is half-wired

### Rotation liveness

- "First writer wins" assumes *someone* writes. If every currently-online member crashes between rotation-trigger and `performRotation` finishing, the rotation never completes. Existing messages still decrypt with the old version; new messages can't be sent at a fresh version.
- There is no deterministic leader. Each member who hears the trigger independently tries to rotate, races on the UNIQUE constraint, and the loser drops out.
- **GitHub issue #658** tracks this. CLAUDE.md "Known Limitations" #2 mentions it.

### Server-side enforcement

- The server's `validate_encrypted_payload` gate (`apps/server/src/ws/message_service/validate.rs:213`) rejects plaintext on encrypted DMs **today**. The encrypted-group branch existed but was misshapen: `is_valid_ciphertext_shape` only knew about the 1:1 wire formats (initial V1/V2 prefix + normal-message `header_len=40`) and tried to base64-decode the entire content. Group ciphertext arrives as `GRP1:<base64>`, and `:` is not a base64 character — so every encrypted-group message was getting silently rejected. Result: encrypted groups couldn't send anything through prod, but plaintext groups still worked.
- This validator was extended with `GRP1:` + `GRP2:` prefix awareness in the same dev branch that produced this doc — see [`docs/group-e2e-design/04-migration-plan.md`](04-migration-plan.md) Phase 1 for the rollout note.
- **GitHub issue #591** tracked "server should reject plaintext sends on encrypted groups"; the fix above closes that gap.

### `@here` / `@everyone` mention semantics

- Plaintext groups: `@here` causes the server to skip APNs push to offline members. Encrypted groups are *unaffected* because the literal text never appears in ciphertext (CLAUDE.md "Signal Protocol crypto" §3).
- This is fine, but worth documenting because the user-visible behaviour diverges across encrypted vs plaintext groups today.

## What is missing entirely

### Membership change → key rotation propagation

- We trigger rotation, but the receiver of a "key changed" event has no graceful way to handle in-flight messages encrypted at the old version while their next outbound at the new version goes through. We rely on the server keeping all versions, which is correct, but the *user* sees nothing — there is no "group key rotated" subtle indicator.

### Removal of a member

- Adding a member: rotate (so the new member can't read pre-add history; this is the privacy property removing-by-rotation gives us).
- Removing a member: rotate (so the removed member can't read future messages). We trigger the rotation, but if the removed member is the one who tries to rotate (race condition), the rotation can be aborted server-side. Not currently handled.

### Forward secrecy at the group level

- Sender Keys (Signal's approach) does *not* provide per-message forward secrecy at the group level — it's "session-level" forward secrecy, broken by rotation. This is an intentional trade-off.
- Our current code matches this trade-off (one group key per version, AES-GCM with per-message random nonce). Worth being explicit about so we don't promise more than we deliver.

## State of activation

- `is_encrypted=true` is **off by default** on group creation.
- A few production groups have it on. The user-visible UX is "messages send", with no real indicator that anything is encrypted differently from a plaintext group, and no audit-log of rotations.

## What this means for the design

We don't need to *replace* what's there — we need to:
1. Fix rotation liveness (deterministic leader).
2. Get server-side ciphertext-only enforcement landing.
3. Tighten the envelope-decrypt fallback (audit P1-3).
4. Add user-visible recovery affordances for the failure modes.
5. *Then* turn encryption on by default for newly-created groups.

The crypto primitives are not the bottleneck. The bottleneck is the failure-mode UX and the liveness gap.
