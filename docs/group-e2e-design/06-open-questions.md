# 06 — Open Questions

*(Restructured after the 4-specialist review. Earlier framing was "9 open questions for stakeholder review" — but Echo is a one-person team and there is no stakeholder pool. Easy questions now ship with a **Default recommendation**; the maintainer signs them off in one sitting. Only OQ-2 and OQ-6 are genuinely open. Five new questions were added by reviewers (OQ-10 through OQ-14).)*

## How to use this file

Each question has:
- **The question itself** — what needs to be decided.
- **Default recommendation** (where reviewers agreed on an obvious default) — the answer the maintainer is expected to either accept or override.
- **Decisions log** — empty until decided. Append `DECIDED YYYY-MM-DD: <answer> — <rationale>` once resolved. This is the audit trail; do not delete the original question.

## Genuinely open (need a 24-hour think)

### OQ-2 — Group size targets

What is the largest group size we plan to support in the next 12 months?

This determines whether Sender Keys is the right answer. ~20 members: Sender Keys is correct. ~200 members: still fine. ~1000+: MLS becomes the right answer and the design in [`03-recommended-protocol.md`](03-recommended-protocol.md) is wrong.

**No default** — this is a product strategy call.

**Decisions log**: *(empty)*

### OQ-6 — Push notifications on encrypted groups

The server cannot read plaintext content in encrypted groups, so the existing push-preview UX breaks. Three options:

- **(a)** Generic *"You have a new message in <group>"* — no sender, no content. Ships everywhere today.
- **~~(b)~~** *"<sender>: <encrypted>"* — sender visible, content opaque. **Retired** after backend review: leaking sender + group identity in the push payload is a metadata-leak privacy regression that runs counter to the project.
- **(c)** Silent push → client decrypts in background → re-posts a local notification with the preview. Requires background-decrypt capability, which currently doesn't exist on web/Linux. Battery cost on mobile.

**Default recommendation** (docs reviewer): start with **(a)** on all platforms. Layer (c) on iOS / Android later when background-decrypt is wired. Web and Linux stay on (a) permanently because they have no background-decrypt path.

**Decisions log**: *(empty)*

## Pre-answered (override if you disagree)

### OQ-1 — Ship the per-message Ed25519 sender signature?

80 bytes per message, ~50 µs per verify. Closes the "anyone with the group key can forge as anyone" attack.

**Default recommendation** (security + backend agreed): **yes, ship it.** The attack is real and unavoidable in raw Sender Keys without a signature. The 80-byte overhead is negligible at expected group sizes. The earlier doc oversold what the signature solves (it does not protect against a compromised sender's own identity key); the framing in [`03-recommended-protocol.md`](03-recommended-protocol.md) §"Per-message authenticity" has been corrected.

**Decisions log**: *(empty — but expected to be DECIDED: yes)*

### OQ-3 — Default-on for new groups, when?

The migration plan ([`04-migration-plan.md`](04-migration-plan.md) Phase 5) flips the default after Phases 1–4 ship.

**Default recommendation**: hold the trigger until **all** of:
- Phases 1–4 have shipped and been in production ≥ 2 weeks with no rotation-failure regressions in telemetry.
- A 2-week beta cohort (e.g. one self-hosted instance of contributors) reports zero `[Could not decrypt…]` placeholders.

**Decisions log**: *(empty)*

### OQ-4 — Migration of existing plaintext groups to encrypted?

Today's plaintext groups stay plaintext. Migrating multi-year plaintext history into an encrypted group has ugly trade-offs (drop history vs re-encrypt-on-enable).

**Default recommendation**: **out of scope.** Document as a product limitation in user-facing FAQ. Users who want encryption migrate by creating a new group and pinning a "moved here" link.

**Decisions log**: *(empty)*

### OQ-5 — Removed members — how strict on history access?

A removed member retains envelopes for old key versions and can decrypt historical messages they participated in.

**Default recommendation**: **retain.** Industry standard (Signal, WhatsApp, iMessage). The privacy property is "no *future* access after removal", not "no *past* access". Document this in `docs/PRIVACY.md`.

**Decisions log**: *(empty)*

### OQ-7 — Keep or delete `core/rust-core/src/signal/`?

The dual-implementation problem from the audit ([`../crypto-audit/05-rust-core-vs-dart.md`](../crypto-audit/05-rust-core-vs-dart.md)).

**Default recommendation** (QA reviewer): **decide AFTER P2-2 lands**, not before. The cross-implementation wire-compat test (5 days infra investment) is the forcing function. Build the harness first; the answer falls out. This is not a product decision; it is an engineer's call once they have the data.

**Decisions log**: *(empty, by design — will be answered post-P2-2)*

### OQ-8 — UI signal for encrypted-ness

Plaintext and encrypted groups look identical today.

**Default recommendation** (docs reviewer): **lock icon in the group header.** Matches Discord/Signal mental model, cheapest to implement, doesn't add per-message noise. Settings panel shows a longer "Encryption: enabled" label with a tap-target to view the safety number.

**Decisions log**: *(empty)*

### OQ-9 — Admin can downgrade an encrypted group to plaintext?

**Default recommendation**: **no, stay one-way.** A malicious or compromised admin could "downgrade" at any time, after which all future messages are server-readable. The audit trail would be visible (per OQ-13 below) but the trust is broken. One-way is consistent with WhatsApp, Signal, iMessage. Document this clearly.

**Decisions log**: *(empty)*

## Reviewer-added questions

### OQ-10 — Per-device envelopes for groups *(backend reviewer)*

`group_key_envelopes` is keyed `(group_id, member_id, key_version)` — one envelope per user. Echo is multi-device. CLAUDE.md Known Limitations #2 confirms multi-device is partial. Two options:

- **Per-user envelopes** (current): all devices for a user share an envelope wrapped under the user's identity key. Key compromise on one device compromises group history for that user across all their devices — but this is also true of the 1:1 stack today.
- **Per-device envelopes**: tuple becomes `(group_id, member_id, device_id, key_version)`. Roughly `N_members × M_devices` envelope rows per version instead of `N_members`. At typical scale (5 devices avg) this is 5× the row count — still small in absolute terms.

**No default yet** — depends on multi-device threat model, which is itself an open project-level question. Not blocking Phase 1 or 2; must be answered before Phase 3 (server-led election needs to know how to enumerate envelope recipients).

**Decisions log**: *(empty)*

### OQ-11 — GRP1→GRP2 downgrade-attack policy *(security reviewer)*

How long do we support `GRP1:` wires after GRP2 ships?

[`04-migration-plan.md`](04-migration-plan.md) Phase 2 now includes a `min_wire_version` field on envelopes so receivers can reject GRP1 at GRP2-only key versions. But the wire-acceptance window — "we never delete GRP1 support" — also needs revisiting.

**Default recommendation**: **flag-day cutover after Phase 5.** Once `is_encrypted=true` is default-on and the cohort soak has completed, set all newly-generated key versions to `min_wire_version=2`. Old key versions remain `min_wire_version=1` indefinitely for historical decrypt. Result: there is no version-N envelope at which a GRP1 downgrade is accepted, but historical messages still decrypt.

**Decisions log**: *(empty)*

### OQ-12 — Multi-device sender signatures *(security reviewer)*

If a user has 3 devices each with their own Ed25519 identity, which signs?

**Default recommendation**: **the sending device signs with its own identity key.** Server delivers (sender_user_id, sender_device_id) as it already does for 1:1. Recipients fetch the (user, device) identity-key bundle if not cached. Server caches all of a user's device-identity public keys. This adds a column to `identity_keys` if not present already (likely is).

**Decisions log**: *(empty)*

### OQ-13 — Server-side audit log of rotations *(security reviewer)*

For incident response (detecting malicious admin downgrade attempts, abnormal rotation frequency).

**Default recommendation**: **yes, with a tight schema.** Add `group_key_rotations(id, conversation_id, triggered_by_user_id, triggered_by_event, key_version, completed_at, completed_by_user_id)`. Cheap, append-only, no GC. Visible to group admins in settings. Tracked as a separate ~1 day work item, not part of the migration plan core.

**Decisions log**: *(empty)*

### OQ-14 — OS-upgrade key durability *(security reviewer)*

macOS Keychain has eaten keys across major-version upgrades historically. Android Keystore has migration bugs across vendor OEMs.

**Default recommendation**: **document, don't engineer around.** The 1:1 stack already handles "keys missing on first launch" via key regeneration + the "previous encrypted messages cannot be decrypted" snackbar. Group recovery uses the same machinery — admin re-triggers a rotation, recipient gets a new envelope. Add an item to release-checklist: test on macOS-N+1 / Android-N+1 betas before each major OS release.

**Decisions log**: *(empty)*

## Removed from the original list

- **OQ-5 ("removed members keep historical access")** was an industry-standard documentation item, not a decision. Kept in the list above for completeness but treated as pre-answered.
- **OQ-8 ("lock icon vs badge vs side-stripe")** was a UI decision, not a crypto decision. Default-answered above; UI/UX team can override.

---

## When this file gets touched

- **Before any code lands in Phase 2**: OQ-1, OQ-11, OQ-12 must be DECIDED.
- **Before Phase 3 lands**: OQ-2, OQ-10 must be DECIDED. OQ-13 should be DECIDED.
- **Before Phase 5 lands**: OQ-3, OQ-4, OQ-6, OQ-9 must be DECIDED. OQ-14 should have a release-checklist follow-up filed.

If you DECIDE an item, edit the corresponding `Decisions log` line in-place. Do not delete the question. Future maintainers reading this six months from now should see both the question and the answer.
