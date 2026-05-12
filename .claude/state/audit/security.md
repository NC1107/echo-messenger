### Finding 1: Avatar uploads buffer up to 100 MB in RAM before the 2 MB size check
- **File**: apps/server/src/routes/groups.rs:965-997 (and apps/server/src/routes/users.rs:640-650)
- **Severity**: high
- **Description**: `upload_group_avatar` and `upload_avatar` consume the entire multipart field with `field.bytes().await` BEFORE checking `data.len() > MAX_GROUP_AVATAR_SIZE` (2 MB). The global `DefaultBodyLimit::max(media::MAX_FILE_SIZE)` set in `routes/mod.rs:243` allows 100 MB per request. The endpoints also have no per-route rate limiter (see `routes/mod.rs:299-301` and `:323`). An authenticated client (any registered user) can repeatedly POST near-100 MB bodies — the server allocates the full payload into a contiguous `Bytes` buffer in memory, then rejects with 400. With concurrent requests this trivially exhausts RSS on the production tini-supervised container. The streaming pattern used by `routes/media.rs::stream_field_to_temp` (peak RAM = O(chunk)) was clearly available and not used here. The recent commit `cfb3c38` widened the accepted field name from `avatar` to `avatar|file`, which lowers the bar for accidental/malicious triggering.
- **Code**:
```rust
let data = field
    .bytes()
    .await
    .map_err(|e| AppError::bad_request(format!("Failed to read avatar data: {e}")))?;
// ...
if data.len() > MAX_GROUP_AVATAR_SIZE { ... }
```
- **Fix**: Stream the field through a chunked loop with a running byte counter that aborts the moment `total_bytes > MAX_GROUP_AVATAR_SIZE` (mirror `stream_field_to_temp`). Add a per-route rate limiter on both avatar PUT endpoints. Optionally tighten the per-request body limit on the avatar routes via a route-scoped `DefaultBodyLimit::max(MAX_GROUP_AVATAR_SIZE)`.
- **Effort**: small

### Finding 2: Password-reset tokens written to application logs at INFO level
- **File**: apps/server/src/routes/auth.rs:451-459
- **Severity**: high
- **Description**: `forgot_password` issues a single-use 15-minute reset token and writes the raw token, username, user_id, and expiry to `tracing::info!`. The comment frames this as "admin-mediated" and an MVP fallback for missing SMTP, but the token grants unconditional password reset and `reset_password` does not require any other proof of identity (see lines 477-522). Threats: (1) production logs ship to centralized log stores (Loki/Datadog/journald) often with broader read access than the DB, (2) a logfile leak/backup leak/compromised log shipper becomes account takeover for every user who triggered forgot-password during the retention window, (3) anyone with `docker logs` access on the prod host (which CLAUDE.md describes as a Watchtower-managed shared box) becomes an unauthenticated attacker against any account.
- **Code**:
```rust
tracing::info!(
    username = %body.username,
    user_id  = %user.id,
    token    = %token,
    expires  = %expires_at,
    "[PASSWORD RESET] Single-use reset token issued. ...",
);
```
- **Fix**: Stop logging the raw token. Either persist it to a server-only sealed table the operator queries with a CLI/admin endpoint, or short-circuit the route until SMTP is wired up. At minimum log only `user_id` and a token *fingerprint* (first 6 chars or sha256 prefix) so an admin can correlate without holding the secret. Document a log-retention compromise procedure.
- **Effort**: small

### Finding 3: New group members are added without rotating the group key
- **File**: apps/server/src/routes/groups.rs:267-390 (`add_member`) and :547-590 (`join_group`)
- **Severity**: medium
- **Description**: `rotate_group_key_after_member_loss` is invoked from `remove_member`, `leave_group`, and `kick` (lines 442/687/831), giving forward secrecy when a member leaves. The symmetric path on join is missing: `add_member` and `join_group` neither bump `key_version` nor broadcast `group_key_rotation_requested`. Combined with how `get_my_group_key_envelope` returns the latest key envelope to any current member, this gives a newly added member a long re-keying window. Concretely: an admin can re-add a previously-removed user and (because the existing latest envelope is still v_N) the re-added user's client receives v_N immediately and can decrypt all v_N ciphertexts that were sent between the previous rotation and now. The Signal Protocol property usually advertised here ("post-compromise security on join / no historical access for new members") is not enforced. CLAUDE.md says group encryption is half-wired, but this specific gap (post-add re-key) isn't called out and is a real divergence from the documented "kicked user can no longer decrypt future ciphertext" guarantee in `routes/groups.rs:28`.
- **Code**:
```rust
let added = db::groups::add_member(&state.pool, group_id, body.user_id)
    .await
    .db_ctx("add_member/insert")?;
// ...broadcasts member_added but NEVER calls rotate_group_key_after_member_loss
```
- **Fix**: After a successful `add_member` / `join_group` on an `is_encrypted` conversation, invoke a `rotate_group_key_after_member_join` that bumps `key_version` and emits `group_key_rotation_requested` to existing members so they re-upload envelopes (including the new member). Alternatively document explicitly in CLAUDE.md that group encryption only protects the leave direction.
- **Effort**: medium

### Finding 4: Media tickets are reusable for 5 minutes — stolen ticket = full media ACL bypass for the user
- **File**: apps/server/src/routes/media.rs:734-753 (`validate_media_ticket`) and :422-450 (`request_media_ticket`)
- **Severity**: medium
- **Description**: `validate_media_ticket` deliberately does NOT consume the ticket on first use ("Tickets are reusable within their 5-minute TTL so that web `<img>` tags can load multiple images"). Combined with the fact that the ticket is passed in the URL query string (`?ticket=` or legacy `?token=`) for `<img src>` and `<video src>` tags, the ticket is exposed in: browser referer headers if any external `<img>`/HTML is rendered with a different origin, browser history, server access logs of any reverse proxy other than Traefik in the chain, and the WebView devtools timeline of any embedded view. A captured ticket grants any caller the *full* media-ACL surface of the user (every conversation they're a member of) for up to 5 minutes — not just the single image the user was loading. The WebSocket ticket flow uses 30 seconds + atomic single-use (`routes/ws.rs:32-50`); this one is intentionally weaker without that being an architectural necessity.
- **Code**:
```rust
let entry = state
    .media_tickets
    .get(ticket)
    .ok_or_else(|| AppError::unauthorized("Invalid or expired media ticket"))?;
// no removal — ticket lives until TTL expires
```
- **Fix**: Either (a) bind the ticket to a single media id at issuance time (`request_media_ticket` takes optional `media_id: Uuid`, ticket is rejected for any other id), or (b) reduce TTL to 30-60 seconds and treat the ticket as a short-lived bearer that the client refreshes. Option (a) is the right long-term answer since it survives ticket leakage. Drop the legacy `?token=` query alias; it confuses the threat model with the real WS ticket.
- **Effort**: medium

### Finding 5: `kick` and `remove_member` purge group key envelopes but never revoke the kicked user's WebSocket session or cached v_old key
- **File**: apps/server/src/routes/groups.rs:393-450, apps/server/src/db/groups.rs:716-740
- **Severity**: medium
- **Description**: When a member is removed, `rotate_group_key_after_member_loss` deletes all rows from `group_key_envelopes` for the conversation and bumps `key_version`. However:
  1. The kicked user's still-open WebSocket connection is not closed — they will continue to receive every fanout broadcast for conversations whose `is_member` check is re-run only at send/read time, not on the existing socket. (The hub is keyed on user_id; nothing in `remove_member` calls `state.hub.disconnect_user` or similar — `grep -n "disconnect_user\|close_user" apps/server/src/ws/hub.rs` returns no matches.)
  2. The kicked user's local client retains the v_old AES key in memory/Hive, so any v_old-encrypted messages they ALREADY received and any v_old ciphertexts that haven't yet been re-encrypted (rotation is async and racy by design — see `routes/groups.rs:36-40`) remain decryptable.
  Point (1) is more severe than the documented "logout all others" gap (CLAUDE.md known limitation #2), because removal-from-a-group is a different action than logout-all-others and most operators won't expect group removal to require a kick of the underlying socket.
- **Code**:
```rust
// db/groups.rs
sqlx::query("DELETE FROM group_key_envelopes WHERE conversation_id = $1")
    .bind(conversation_id)
    .execute(&mut *tx)
    .await?;
// (no hub-side eviction of the removed member)
```
- **Fix**: After successful `remove_member`/`kick`, send a `kicked` server event to the removed user_id and either close their socket entirely or strip the conversation from their per-socket subscription list. At minimum, also re-check `is_member` inside `fanout_message`'s eligibility filter (it currently only excludes blockers and the sender) so a stale member-set cache cannot deliver new ciphertext to a removed user.
- **Effort**: small

### Finding 6: Reaction emoji accepts whitespace-only and unbounded Unicode codepoints up to 32 bytes
- **File**: apps/server/src/routes/reactions.rs:42
- **Severity**: low
- **Description**: `add_reaction` rejects `body.emoji.is_empty() || body.emoji.len() > 32` but does not trim. A client can submit `"   "` (or RTL/zero-width characters) and persist a reaction row that surfaces as a blank reaction chip in the UI. The fix mirrors the recent `0ca58a2` pattern on message edit (`routes/messages.rs:448`). Lower severity because reactions are display-only, but spam abuse and UI confusion are real (one of the april backlog items called out blank reactions).
- **Code**:
```rust
if body.emoji.is_empty() || body.emoji.len() > 32 {
```
- **Fix**: Replace with `if body.emoji.trim().is_empty() || body.emoji.chars().count() > 8` (or use a unicode-segmentation crate to count grapheme clusters, capped at 1-2 graphemes). Reject control characters and bidi overrides explicitly.
- **Effort**: small

### Finding 7: `validate_password` enforces length only — no entropy / common-password / breach check
- **File**: apps/server/src/routes/auth.rs:108-120
- **Severity**: low
- **Description**: `validate_password` only checks 8 ≤ len ≤ 128. `register` and `reset_password` both call this. A user can pick `"password"`, `"12345678"`, or any breached credential. Combined with the in-memory rate limiter (`CLAUDE.md` known limitation #4) that resets on server restart, online brute force becomes practical against accounts the attacker has guessed usernames for (and the server emits a cleanly differentiated `WrongPassword` error code so attackers know when they're hitting a real user). The documented argon2id cost makes offline brute-force expensive, but it does not help here.
- **Code**:
```rust
fn validate_password(password: &str) -> Result<(), AppError> {
    if password.len() < 8 { ... }
    if password.len() > 128 { ... }
    Ok(())
}
```
- **Fix**: Add a minimum-entropy gate (zxcvbn-rs or a curated common-password blocklist of ~10k entries via `phf`). Optionally raise the minimum length to 10 and reject when `password.contains(username)` (case-insensitive). Pair with persistence-backed rate limiting (already on the roadmap).
- **Effort**: small

### Finding 8: `Header::default()` for JWT issuance does not pin the algorithm
- **File**: apps/server/src/auth/jwt.rs:38-42
- **Severity**: low
- **Description**: `create_token` uses `Header::default()` (HS256) and `validate_token` uses `Validation::default()`. `Validation::default()` happens to allow only HS256, which closes the alg-confusion attack today, but this is implicit and brittle: if a future jsonwebtoken upgrade or a refactor touches `Validation::new(Algorithm::HS256)` vs `default()`, the safety property silently breaks. The repo is already pinned to a jsonwebtoken version with a known-and-WONTFIX timing sidechannel (RUSTSEC-2023-0071), and there's no test asserting that an attacker-supplied `alg: none` or `alg: RS256` token is rejected.
- **Code**:
```rust
let token = encode(
    &Header::default(),
    &claims,
    &EncodingKey::from_secret(secret.as_bytes()),
)?;
// ...
let mut validation = Validation::default();
```
- **Fix**: Replace `Validation::default()` with `Validation::new(Algorithm::HS256)` and add explicit unit tests that (a) `alg: none` tokens are rejected, (b) RS256-signed tokens with a public key matching the HS256 secret bytes are rejected. Same for the APNs JWT flow in `push.rs` (which already uses ES256 explicitly — fine, but worth adding the assertion).
- **Effort**: small

### Finding 9: `JWT_SECRET` length-only check accepts low-entropy 32-byte strings
- **File**: apps/server/src/config.rs:21-26
- **Severity**: low
- **Description**: The startup assertion only checks `jwt_secret.len() >= 32`. A 32-byte value of `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"` or `"echo-messenger-jwt-secret-please"` passes. HS256 strength is bounded by the secret entropy; once it leaks (or is guessable), all tokens are forgeable forever (no rotation mechanism in the code). Recent ops practice has hosters using docker-compose `.env` files with manually-typed secrets exactly because the docs say "≥32 chars" without specifying entropy.
- **Code**:
```rust
assert!(
    jwt_secret.len() >= 32,
    "JWT_SECRET must be at least 32 characters for security"
);
```
- **Fix**: Add a Shannon-entropy floor (e.g. ≥ 4.0 bits/char on the byte distribution) and reject obvious patterns (all-same-byte, ASCII-only short strings). Print a startup hint suggesting `openssl rand -base64 48`. Document the rotation procedure (currently undocumented; rotation will invalidate every issued access+refresh token in flight).
- **Effort**: small

### Finding 10: `get_thread_replies` accepts negative `limit` values and forwards them to SQL
- **File**: apps/server/src/routes/messages.rs:548 (and :356 `get_messages` has the same shape)
- **Severity**: low
- **Description**: `let limit = params.limit.unwrap_or(50).min(100);` — `.min(100)` clamps the upper bound but not the lower. A user-supplied `?limit=-1` flows directly to `db::messages::get_thread_replies` and into a Postgres `LIMIT $N` bind, which Postgres rejects with `ERROR: LIMIT must not be negative`. The 500 response is harmless on its own, but the same pattern appears across routes (`get_messages` line 356, `search_messages`, others) and a pattern of unvalidated query ints often hides off-by-one or panic conditions. More importantly, it passes the negative integer to a query that runs against the messages table with no early-validation check — wasted DB round-trip on every malformed request, easy to script-spam.
- **Code**:
```rust
let limit = params.limit.unwrap_or(50).min(100);
```
- **Fix**: Use `params.limit.unwrap_or(50).clamp(1, 100)` everywhere `limit` is taken from user input. Audit `routes/messages.rs:356`, `:548`, plus `search_messages` and any `pub struct *Query { pub limit: Option<i64> }` consumer.
- **Effort**: small
