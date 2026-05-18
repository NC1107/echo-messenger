# 06 — Open Questions

Things we still need to decide before implementation starts. Each ties back to either an audit finding or an unknown the explore phase surfaced. Listed in the order they need answers.

## OQ-1 — Do we ship per-message sender signatures?

The recommended protocol in [`03-recommended-protocol.md`](03-recommended-protocol.md) includes an Ed25519 signature on every group message. ~80 bytes / ~50 µs per message.

Trade-off:
- **Pro**: solves the "anyone with the group key can forge as anyone" attack. Closes a real attacker model.
- **Con**: 80 bytes × N members × every-message bandwidth, and a verify on every receive. Negligible for small groups; non-negligible at 100+ members on metered connections.

**Decision needed**: ship the signature, or skip it (treat group-key-possession as identity proof, trust the server's `from_user_id`)?

Ties to: audit [`02-message-loss-surface.md`](../crypto-audit/02-message-loss-surface.md) — currently no signature, so this is purely a *new* feature in GRP2.

## OQ-2 — Group size targets

The design picks Sender Keys precisely because Echo's typical group is small. If product expects 100+-member groups within a year, MLS becomes the right answer (see [`02-protocol-options.md`](02-protocol-options.md)) and our migration path looks very different.

**Decision needed**: what's the largest group size we plan to support in the next 12 months?

Ties to: [`02-protocol-options.md`](02-protocol-options.md) "Decision matrix".

## OQ-3 — Default-on for new groups, when?

The migration plan ([`04-migration-plan.md`](04-migration-plan.md) Phase 5) defaults `is_encrypted=true` for new groups after audit P0 + Phases 1–4 ship. That's roughly 6 weeks of work.

**Decision needed**: are we OK with the default-on gate, or do we want a longer soak / beta cohort first?

Ties to: audit `06-recommendations.md` and `crypto-audit/02-message-loss-surface.md`.

## OQ-4 — Migration of existing plaintext groups?

GRP2 ships for *new* encrypted groups. Existing plaintext groups stay plaintext. We do not currently have a design for migrating a multi-year plaintext history into an encrypted group.

**Decision needed**: is "you cannot retro-encrypt a plaintext group" an acceptable product limitation, or do we need a migration story?

If migration is needed, options range from "drop the history" (user-hostile) to "client-side re-encrypt the last N messages on enable" (re-introduces the message-loss surfaces we're trying to close). Both have ugly trade-offs.

## OQ-5 — Removed members — how strict on history access?

Today, a removed member retains envelopes for old key versions and can decrypt historical messages they participated in. GRP2 doesn't change that.

**Decision needed**: should we wipe historical envelopes from removed members' devices server-side (impossible — we don't control their device), or is local-history-retention by removed members acceptable?

Industry standard (Signal, WhatsApp, iMessage): yes, historical access is retained. The privacy property is "no *future* access after removal", not "no *past* access".

## OQ-6 — Push notifications on encrypted groups

The plaintext message preview shown in OS-level push notifications cannot survive E2E encryption. Echo currently relies on the server seeing plaintext to populate that preview.

**Decision needed**: in encrypted groups, do push notifications show:
- (a) `"You have a new message in <group>"` — generic, no content.
- (b) `"<sender>: <encrypted>"` — sender visible (we know it server-side), content opaque.
- (c) Trigger a silent push, client decrypts in the background, then re-posts a local notification with the decrypted preview. (Battery cost; requires background-decrypt capability which currently doesn't exist on web/Linux.)

CLAUDE.md mentions `@here` causes the server to skip push for offline members. That mechanism breaks for encrypted groups — the server can't read the `@here` marker.

Ties to: GRP2 "is the literal text invisible to server" property.

## OQ-7 — Cross-implementation wire-compat — keep rust-core or delete?

[`../crypto-audit/05-rust-core-vs-dart.md`](../crypto-audit/05-rust-core-vs-dart.md) recommends adding a wire-compat test (P2-2) and deferring the delete-vs-formalise decision for one sprint.

**Decision needed at the end of that sprint**: keep `core/rust-core/src/signal/*`, or delete it?

This is *not* blocking on GRP2 — both implementations need to support GRP2 if we keep both, which is a real cost. If we delete rust-core's Signal port, we sidestep that cost.

## OQ-8 — How do we surface "this group is encrypted" to the user?

Plaintext and encrypted groups currently look identical in the UI. Should we:
- Add a lock icon in the group header? (Discord-style)
- Add a "Encrypted" badge in group settings only? (Discord-style for verified servers)
- Add a per-message side-stripe like in Threema / Wire? (Heaviest signal, also noisiest)

**Decision needed**: pick one. None of the options is wrong; consistency matters more than which.

## OQ-9 — Admin can downgrade an encrypted group to plaintext?

Today, `is_encrypted` is a one-way switch (encryption on at create time, you can't turn it off). Should that remain?

Risk if downgradeable: a malicious or compromised admin could "downgrade" a group at any time, after which all future messages are server-readable. Members would see a clear UI signal (one of OQ-8) but the history-of-trust is now broken.

**Decision needed**: stay one-way (current behaviour, recommended) or allow downgrade with a hard prompt?

---

These all need answers before the first code-modifying PR lands. Suggest: spend one product-review session walking the list with stakeholders. None of the answers should be invented unilaterally.
