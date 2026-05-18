# 05 — Message-Loss Analysis

The whole point. Every place a group message could be lost in the new design, with the design's specific answer.

The headline question from the user — *"I fear losing user messages due to the finickiness of the encryption setup"* — applied to GRP2.

## How these scenarios get tested

Per the QA review pass on this design, the 10 scenarios below need different test layers:

- **Unit-testable**: L1, L2 (server-only), L5, L6, L7 (server-only), L8 (server-only extension), L10.
- **Needs multi-client simulation harness**: **L4** (rotation never completes) and **L9** (client crashes mid-send). Neither is exercisable by today's test infrastructure. The harness itself is tracked as audit item P1-1 (see [`../crypto-audit/06-recommendations.md`](../crypto-audit/06-recommendations.md)) and **must land before this phase's Phase 3** so the rotation-state-machine work has a place to be tested.

Without the harness, Phases 3+ would ship without coverage of the failure modes the design claims to close. That is the same trap that left GRP1 half-wired — design says "we handle X", code says "we trust we handle X", no test exists to confirm.

## L1 — Sender has no active group key cached

- **Scenario**: First message after launch; cache is cold; network is flaky.
- **Today (GRP1)**: `sendGroupMessage` hard-fails, message rendered in "failed" state in the chat UI. Already correct.
- **GRP2**: identical behaviour. We do not make this worse.

## L2 — Sender's cached key is stale (group rotated while sender was offline)

- **Scenario**: Sender went offline at v1; group rotated to v2; sender comes back and sends a message encrypted at v1.
- **Today (GRP1)**: server stores the v1 ciphertext; v2 members decrypt at v1 (they retain v1 envelopes) and read the message. No loss.
- **GRP2**: same behaviour. Server still retains all key versions.
- **Edge case**: sender is offline long enough that they were *removed* from the group before they come back online. In this case the server's send endpoint should reject the send (they are no longer a member) — see [`03-recommended-protocol.md`](03-recommended-protocol.md) §"Server-side enforcement". Message fails fast, user sees a "you are no longer in this group" banner. No silent loss.

## L3 — Receiver missing the active key version

- **Scenario**: Receiver was offline during the rotation; comes back online; doesn't yet have a v2 envelope on disk.
- **Today (GRP1)**: receiver fetches active version on demand → decrypts. Works unless the fetch fails silently.
- **GRP2**: receiver fetches active version; on failure, recovery banner (Phase 4 UX) prompts retry. Failure is *loud*, not silent.

## L4 — Rotation never completes (the audit's MED-3 finding)

- **Scenario**: rotation triggered, no member completes it before going offline.
- **Today (GRP1)**: group is wedged; new sends at v2 can't happen. Existing v1 still works.
- **GRP2**: deterministic leader election (`03-recommended-protocol.md` §"Rotation flow with deterministic leader election") plus a 1.5 s × rank staggered fallback ensures *one* online member completes the rotation. Liveness gap from #658 is closed.
- **Worst case**: all members are offline. Rotation runs on the next online member. No data loss; just a delay.

## L5 — Envelope decrypt fallback misinterprets bytes (the audit's MED-4 finding)

- **Scenario**: Envelope unwrap fails; code at `group_crypto_service.dart:225` falls back to treating raw bytes as the legacy plaintext group key.
- **Today (GRP1)**: AEAD on the actual message decrypt catches the bad key; user sees `[Could not decrypt…]` for every group message.
- **GRP2**: still uses AEAD-on-decrypt, plus we add the audit P1-3 sanity check at unwrap time. Fail-fast at unwrap, not at every message decrypt. User sees a "rotate key" banner (Phase 4 UX) instead of an endless stream of decrypt failures.

## L6 — Sender signature verification fails

- **Scenario**: Sender signature does not match the from-user's identity key. Either: (a) the wire is corrupted, (b) the sender's identity-key cache is stale, (c) someone with the group key is forging.
- **GRP2**: hard rejection. Message rendered with `[Could not verify sender]` placeholder and a danger-coloured side stripe.
- **Recovery**: receiver re-fetches the sender's identity key from the server and retries the verify. If still fails, the user is alerted; no automatic acceptance.
- **Not a loss scenario** — the message *is* delivered to the UI, just flagged. The user can see the ciphertext arrived and that we refused to trust it. Different from "lost".

## L7 — Server rejects a sender's plaintext on an encrypted group

- **Scenario**: An old client tries to send plaintext on an `is_encrypted=true` group after Phase 1 ships.
- **GRP2 / Phase 1**: server returns an error; the *client* renders the message in "failed" state. The user sees "this message could not be sent — your app may be out of date". No silent loss; clear action.

## L8 — Concurrent admin actions cause inconsistent member views

- **Scenario**: Admin A adds X. Admin B removes Y. Both rotate concurrently. The rotations race.
- **GRP2**: server-side `(conversation_id, key_version) UNIQUE` resolves the race. Loser re-fetches member list and retries. We accept that for a fraction of a second the member views may disagree across clients; the *content* of the rotations is safe.
- **Not a loss scenario** — both messages from before the rotation decrypt with v1; both messages after the rotation decrypt with vN (whichever wins).

## L9 — A client crashes mid-send (after server stored, before local persist)

- **Scenario**: Sender's encrypt succeeds, WS frame sent, server stored, server broadcasted. Client crashes before saving "sent" state to its local DB.
- **GRP2**: identical to today's 1:1 and GRP1 behaviour. On restart, the client reconciles with the server; the message reappears in the chat list with "delivered" state derived from the server's history. No loss.

## L10 — Recipient device is wiped (key regeneration scenario)

- **Scenario**: User reinstalls the app or wipes their device. New identity key. They are still a member of the group on the server.
- **GRP2**: server retains old envelopes wrapped under the old identity key. The new identity key has zero envelopes until a rotation runs (which a current member must initiate after the recipient re-keys). All messages from before the wipe are permanently undecryptable on the new device — *by design*, identical to the 1:1 case.
- **UX hook**: the existing "Previous encrypted messages cannot be decrypted" snackbar from `splash_screen.dart:228` already covers the user-facing surface. Group recovery requires a rotation, triggered from group settings.

## Summary

GRP2 adds **zero new** message-loss surfaces compared to GRP1. It closes three existing ones (L4, L5, plus the "no signal on decrypt failure" UX gap) and surfaces L6 cleanly. The trade-offs (no group-level per-message forward secrecy, no anonymous membership) are inherited from the Sender Keys family and are called out in [`03-recommended-protocol.md`](03-recommended-protocol.md) §"What the design does not do".

The user's worry is well-founded *for the current state*. The design's job is to leave them less worried. If anything in this analysis still keeps them up at night, it lands in [`06-open-questions.md`](06-open-questions.md) for explicit decision.
