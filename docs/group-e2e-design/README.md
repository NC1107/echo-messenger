# Group End-to-End Encryption — Design Proposal

A design exercise for extending Echo's existing (half-wired) group-key envelope infrastructure into a complete group E2E protocol, written so that **the failure modes catalogued in the [crypto audit](../crypto-audit/) get worse only over the user's dead body**.

## Why this doc exists

Echo today has solid 1:1 encryption (Signal Protocol). Group chats fall into one of two states:
- **Plaintext groups** (default today): server sees every group message in cleartext.
- **`is_encrypted=true` groups**: a partial implementation exists — see [`01-current-state.md`](01-current-state.md) — but it is not enabled in production because rotation does not have a liveness guarantee, the server doesn't enforce ciphertext-only, and the user UX for failure cases is poor.

The product question is: *do we ship group E2E, and if so, how do we ship it without making message loss worse?*

## Read this in order

| File | What it covers |
|------|----------------|
| [01-current-state.md](01-current-state.md) | What's already built. What works, what's half-wired, what's missing. |
| [02-protocol-options.md](02-protocol-options.md) | Three honest options — Sender Keys, MLS, and a minimal-extension of what we already have. Trade-offs without hand-waving. |
| [03-recommended-protocol.md](03-recommended-protocol.md) | The pick: minimal-extension Sender Keys plus deterministic leader election. Wire format, key lifecycle, membership change. |
| [04-migration-plan.md](04-migration-plan.md) | How to get from today's GRP1 state to the recommended end state, including backward compatibility and rollout gates. |
| [05-message-loss-analysis.md](05-message-loss-analysis.md) | The whole audit's lens applied to the new design. Every place a group message could be lost; the design's answer for each. |
| [06-open-questions.md](06-open-questions.md) | Things we still need to decide before implementation starts. Each ties back to an audit finding or an unknown the explore phase surfaced. |

## TL;DR (read this if you read nothing else)

- **Don't pick MLS.** It's the right protocol for groups of 1000+, with formal security proofs and the right primitives. It is the wrong protocol for Echo's *current* group sizes (most groups are 3–20 members) and engineering bandwidth (one-engineer team).
- **Don't reinvent.** Use the Sender Keys pattern (Signal's own group approach) since we already have most of the building blocks: per-member ECDH-wrapped envelopes, AES-256-GCM symmetric encryption, server-side first-writer-wins rotation guard. We're 70% of the way there.
- **The work is not the crypto — it's the failure modes.** Rotation liveness, key-fetch retry, "I can't decrypt this group" recovery, server-side ciphertext enforcement. These are the items the audit told us to worry about; they remain the items.
- **One PR for code, one PR for server-side ciphertext-only enforcement, one PR for the UX.** Sequenced so we never have a state in production where group E2E "works" but corrupt-rotation can wedge real users.

## What this doc is *not*

- A formal protocol spec. We reference Signal's published Sender Keys spec rather than re-deriving it.
- A timeline commitment. Numbers in `04-migration-plan.md` are calendar estimates for one engineer, not promises.
- A justification for shipping group E2E *next*. The audit's P0/P1 items come first. Group E2E is gated on the keyring-failure and OTP-heal fixes landing — see [`04-migration-plan.md`](04-migration-plan.md) "Pre-requisites".
