# 02 — Protocol Options

Three honest options. Each is described as a *protocol choice* — UX work is the same for all three.

## Option A — Minimal extension of GRP1 (Sender Keys-style)

What Signal Messenger ships for groups today. We are 70% of the way there already.

**Crypto**:
- One symmetric AES-256-GCM key per group, per version (already shipping).
- Per-member envelopes wrapping the group key under each member's X25519 identity key (already shipping).
- Rotation on membership change or N-day schedule (we have the trigger; need the leader-election).
- Per-message random 12-byte nonce, AEAD tag (already shipping).

**What's new vs today**:
- Deterministic leader-election for rotation (closes #658).
- Server-side ciphertext-only enforcement on `is_encrypted=true` groups (closes #591).
- Recovery UX for "I cannot decrypt this group's messages — get a new key version".
- Sanity-check on envelope unwrap (audit P1-3).

**Security properties**:
- Confidentiality from the server: yes (after #591 lands).
- Authenticity of sender: weak — anyone with the group key can produce ciphertext that appears to come from anyone. Mitigations: sign each ciphertext with the sender's identity key (small cost, large benefit) or rely on socket-level "from_user_id" set by the server. We pick the **signed-by-sender** path — see [`03-recommended-protocol.md`](03-recommended-protocol.md).
- Forward secrecy: session-level only, broken by rotation. Same trade-off as Signal's group protocol.
- Post-compromise security: rotation-based. Same trade-off as Signal's group protocol.

**Engineering cost**: 2–3 weeks calendar, single engineer. Mostly UX + server enforcement, not crypto.

## Option B — Full MLS (Messaging Layer Security)

The IETF standard for group messaging. Tree-based key derivation, formal security proofs, supports groups of 50,000+ members.

**Crypto**:
- TreeKEM key derivation (binary tree of ratchets).
- One ciphersuite. Signed group operations. Welcome / commit / proposal protocol.
- Built-in handling of partial group state, asynchronous joins, member removal.

**What's new vs today**:
- Everything. We are not 70% of the way there — we are 5% of the way there.
- Need an MLS library (Rust: `openmls`; no good Dart-native option). Brings back the FFI question we just side-stepped (see [`../crypto-audit/05-rust-core-vs-dart.md`](../crypto-audit/05-rust-core-vs-dart.md)).
- Server-side needs a new "delivery service" component (per MLS architecture).

**Security properties**:
- Best in class. Formal proofs. Post-compromise security per group operation.

**Engineering cost**: 8–16 weeks calendar. Adds ~25k LOC of dependency surface. Comes with an FFI integration question we are deliberately deferring.

## Option C — Per-pair Signal sessions, replicate for every group message

Send each group message as N separate 1:1 Signal-encrypted messages (one per group member). No group key at all.

**Crypto**:
- Reuse the 1:1 Signal Protocol stack we already have.
- Zero new crypto code.

**Security properties**:
- Best for 1:1 confidentiality (per-pair Double Ratchet).
- Per-message forward secrecy on every leg.
- *Worst* for metadata: server sees N copies of every send and can correlate them by timing + identical-size envelopes.

**Engineering cost**: Smallest crypto cost; largest *operational* cost. N× WebSocket fanout per message. For a 20-member group, every send is 20 ciphertexts. Bandwidth, server load, push-notification fanout all multiply.

## Decision matrix

| Criterion | Option A (Sender Keys) | Option B (MLS) | Option C (Per-pair) |
|-----------|------------------------|----------------|---------------------|
| Crypto complexity | Low (we have most of it) | High | Lowest |
| Engineering cost | 2–3 wk | 8–16 wk | 1 wk crypto + ongoing ops |
| Performance at N=20 | Excellent | Excellent | Poor (N× fanout) |
| Performance at N=200 | Good | Excellent | Untenable |
| Forward secrecy granularity | Session (rotation-bounded) | Per operation | Per message |
| Maturity of building blocks in our codebase | Most exist | None exist | All exist |
| Risk of new message-loss bugs (this is the user's #1 concern) | Low (we tighten existing code) | High (new code surface) | Low (reuses 1:1 stack) |
| Metadata leakage to server | Lowest | Lowest | Worst |

## Recommendation

**Option A.** It is the lowest-cost, lowest-risk, lowest-message-loss-surface choice that gives us real group E2E. It matches the engineering reality of the codebase (most pieces exist), and it matches Echo's product reality (groups are 3–20 members, not 200+).

We defer MLS as a future consideration once Echo's product surface stabilises and we have FFI/WASM build infrastructure for free.

We reject Option C because the bandwidth + push-fanout cost makes "encrypted groups" a noticeably worse product than "plaintext groups" for the user — exactly the wrong incentive structure.

The pick is detailed in [`03-recommended-protocol.md`](03-recommended-protocol.md).
