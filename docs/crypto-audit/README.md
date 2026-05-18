# Crypto Audit — May 2026

A focused, evidence-based review of Echo Messenger's end-to-end encryption stack. Written in response to a single product concern:

> *"I fear losing user messages due to the finickiness of the encryption setup."*

Every finding in this audit answers that question: **can this code path silently lose, corrupt, or wedge a message?** Performance, correctness, and architecture concerns are graded against that yardstick.

## Scope

In scope:
- Dart-side Signal Protocol implementation (X3DH + Double Ratchet) — the production code path.
- Session lifecycle (cache, eviction, secure-storage persistence, recovery).
- Wire-format parsing (V1 / V2 initial + normal-message framing).
- Group-message envelope code that exists but is half-wired (covered in detail by the companion design doc).
- The dual-implementation problem: `core/rust-core` ships Signal primitives but the client never calls them.

Out of scope:
- Server-side ciphertext storage and SQL access patterns (audited separately).
- Authentication / JWT / refresh tokens.
- LiveKit voice/video encryption (handled inside LiveKit's own stack, not ours).
- Threat model formalisation — assumed inherited from Signal's published threat model where Echo follows the spec.

## How to read this audit

| File | What it covers |
|------|----------------|
| [01-architecture-map.md](01-architecture-map.md) | File inventory, message paths, wire-format reference |
| [02-message-loss-surface.md](02-message-loss-surface.md) | **The headline.** Every code site where a message can be silently lost, with `file:line` + severity + mitigation status |
| [03-correctness-vs-signal.md](03-correctness-vs-signal.md) | Does our Dart re-implementation match the Signal spec? Per-area conformance checklist |
| [04-performance.md](04-performance.md) | Crypto in init order, isolate use, where it blocks the UI |
| [05-rust-core-vs-dart.md](05-rust-core-vs-dart.md) | The two-implementation problem and what to do about it |
| [06-recommendations.md](06-recommendations.md) | Prioritised P0 / P1 / P2 backlog tied back to specific findings |

The companion doc — [../group-e2e-design/](../group-e2e-design/) — proposes how to extend the existing group-key envelope infrastructure into a real group E2E protocol **without making the message-loss problem worse**.

## Reading order if short on time

1. `02-message-loss-surface.md` — the actionable risk inventory.
2. `06-recommendations.md` — what to do this sprint, next sprint, and later.
3. Everything else, as needed.

## What this audit is *not*

- A line-by-line code review. We trust unit tests for line-level correctness.
- A formal protocol verification. We compare against the Signal spec by intent; we did not run TLA+.
- A penetration test. No active probing of the live server.
- Permission to start implementing fixes. Findings are logged; the user decides scope.
