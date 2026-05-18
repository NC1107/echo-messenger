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

**Decisions log**:
- **DECIDED 2026-05-18**: target <50 members for the next 12 months. Sender Keys is the right protocol; design in `03-recommended-protocol.md` stands. Echo's typical groups today are 3–20 members; <50 leaves comfortable headroom without forcing an MLS detour. If product later moves toward broadcast-style or 500+ member groups, revisit then.

### OQ-6 — Push notifications on encrypted groups

The server cannot read plaintext content in encrypted groups, so the existing push-preview UX breaks. Three options:

- **(a)** Generic *"You have a new message in <group>"* — no sender, no content. Ships everywhere today.
- **~~(b)~~** *"<sender>: <encrypted>"* — sender visible, content opaque. **Retired** after backend review: leaking sender + group identity in the push payload is a metadata-leak privacy regression that runs counter to the project.
- **(c)** Silent push → client decrypts in background → re-posts a local notification with the preview. Requires background-decrypt capability, which currently doesn't exist on web/Linux. Battery cost on mobile.

**Default recommendation** (docs reviewer): start with **(a)** on all platforms. Layer (c) on iOS / Android later when background-decrypt is wired. Web and Linux stay on (a) permanently because they have no background-decrypt path.

**Decisions log**:
- **DECIDED 2026-05-18**: option (a) generic-only on all platforms. Show "You have a new message in <group>" — no sender, no content. Ships everywhere today, no background-decrypt dependency, lowest metadata leak. Layering option (c) silent-push later is left as an unscheduled product opportunity.

## Pre-answered (override if you disagree)

### OQ-1 — Ship the per-message Ed25519 sender signature?

80 bytes per message, ~50 µs per verify. Closes the "anyone with the group key can forge as anyone" attack.

**Default recommendation** (security + backend agreed): **yes, ship it.** The attack is real and unavoidable in raw Sender Keys without a signature. The 80-byte overhead is negligible at expected group sizes. The earlier doc oversold what the signature solves (it does not protect against a compromised sender's own identity key); the framing in [`03-recommended-protocol.md`](03-recommended-protocol.md) §"Per-message authenticity" has been corrected.

**Decisions log**:
- **DECIDED 2026-05-18**: ship the Ed25519 sender signature. Required for GRP2 wire format. Combined with OQ-2's <50-member target the 80-byte/per-message + 50µs/verify cost is negligible. Phase 2 client work proceeds with the signature included.

### OQ-3 — Default-on for new groups, when?

The migration plan ([`04-migration-plan.md`](04-migration-plan.md) Phase 5) flips the default after Phases 1–4 ship.

**Default recommendation**: hold the trigger until **all** of:
- Phases 1–4 have shipped and been in production ≥ 2 weeks with no rotation-failure regressions in telemetry.
- A 2-week beta cohort (e.g. one self-hosted instance of contributors) reports zero `[Could not decrypt…]` placeholders.

**Decisions log**:
- **DECIDED 2026-05-18** *(override of the recommended 2-week soak)*: flip default-on **immediately after Phase 4 ships**, no calendar-driven soak window. Rationale: the P0/P1 audit work has already closed the loud-fail UX paths (P0-1 keyring, P0-2 OTP heal, P0-3 wedged-session reset) AND the multi-client simulation harness (P1-1) exercises the rotation failure modes. Waiting two weeks past Phase 4 is calendar theatre when telemetry already exists. If P1-4 perf telemetry surfaces a regression, the rollback plan in `04-migration-plan.md` reverts via one config flag.

### OQ-4 — Migration of existing plaintext groups to encrypted?

Today's plaintext groups stay plaintext. Migrating multi-year plaintext history into an encrypted group has ugly trade-offs (drop history vs re-encrypt-on-enable).

**Default recommendation**: **out of scope.** Document as a product limitation in user-facing FAQ. Users who want encryption migrate by creating a new group and pinning a "moved here" link.

**Decisions log**:
- **DECIDED 2026-05-18**: out of scope. Document as a known limitation in user-facing FAQ. Industry standard (Signal, WhatsApp). Users migrate by creating a new encrypted group and pinning a "moved here" link in the old plaintext one.

### OQ-5 — Removed members — how strict on history access?

A removed member retains envelopes for old key versions and can decrypt historical messages they participated in.

**Default recommendation**: **retain.** Industry standard (Signal, WhatsApp, iMessage). The privacy property is "no *future* access after removal", not "no *past* access". Document this in `docs/PRIVACY.md`.

**Decisions log**:
- **DECIDED 2026-05-18**: retain. Match Signal / WhatsApp / iMessage semantics. The privacy property we guarantee is "no future access after removal", not "no past access". Follow-up: update `docs/PRIVACY.md` to state this explicitly so it's not a hidden assumption.

### OQ-7 — Keep or delete `core/rust-core/src/signal/`?

The dual-implementation problem from the audit ([`../crypto-audit/05-rust-core-vs-dart.md`](../crypto-audit/05-rust-core-vs-dart.md)).

**Default recommendation** (QA reviewer): **decide AFTER P2-2 lands**, not before. The cross-implementation wire-compat test (5 days infra investment) is the forcing function. Build the harness first; the answer falls out. This is not a product decision; it is an engineer's call once they have the data.

**Decisions log**:
- **DECIDED 2026-05-18**: deferred until P2-2 (wire-compat harness) lands. The cross-implementation test will tell us whether maintaining the Rust port in sync is painful or smooth — that determines whether we keep it as a spec reference or drop it. No code action this sprint; tracked as a follow-up.

### OQ-8 — UI signal for encrypted-ness

Plaintext and encrypted groups look identical today.

**Default recommendation** (docs reviewer): **lock icon in the group header.** Matches Discord/Signal mental model, cheapest to implement, doesn't add per-message noise. Settings panel shows a longer "Encryption: enabled" label with a tap-target to view the safety number.

**Decisions log**:
- **DECIDED 2026-05-18**: lock icon in group header. Settings panel shows the fuller "Encryption: enabled" label with a tap-target to view the safety number. Matches Discord/Signal mental model; no per-message noise.

### OQ-9 — Admin can downgrade an encrypted group to plaintext?

**Default recommendation**: **no, stay one-way.** A malicious or compromised admin could "downgrade" at any time, after which all future messages are server-readable. The audit trail would be visible (per OQ-13 below) but the trust is broken. One-way is consistent with WhatsApp, Signal, iMessage. Document this clearly.

**Decisions log**:
- **DECIDED 2026-05-18**: stay one-way. Once `is_encrypted=true` is set on a group, it cannot be flipped back to plaintext. Consistent with WhatsApp / Signal / iMessage. Closes the "compromised admin downgrades and starts reading messages" attack. Document in `docs/PRIVACY.md`.

## Reviewer-added questions

### OQ-10 — Per-device envelopes for groups *(backend reviewer)*

`group_key_envelopes` is keyed `(group_id, member_id, key_version)` — one envelope per user. Echo is multi-device. CLAUDE.md Known Limitations #2 confirms multi-device is partial. Two options:

- **Per-user envelopes** (current): all devices for a user share an envelope wrapped under the user's identity key. Key compromise on one device compromises group history for that user across all their devices — but this is also true of the 1:1 stack today.
- **Per-device envelopes**: tuple becomes `(group_id, member_id, device_id, key_version)`. Roughly `N_members × M_devices` envelope rows per version instead of `N_members`. At typical scale (5 devices avg) this is 5× the row count — still small in absolute terms.

**No default yet** — depends on multi-device threat model, which is itself an open project-level question. Not blocking Phase 1 or 2; must be answered before Phase 3 (server-led election needs to know how to enumerate envelope recipients).

**Decisions log**:
- **DECIDED 2026-05-18**: per-user envelopes for Phase 2. `(group_id, member_user_id, key_version)` keying stays as-is. Matches the 1:1 stack's existing per-user trust model — a stolen device already has access to the user's 1:1 sessions, so adding per-device envelopes for groups would not meaningfully tighten compromise containment. Revisit if/when we promote multi-device device-id revocation to a P0 in the audit. OQ-12 (sender signing) is per-device regardless; the asymmetry is intentional.

### OQ-11 — GRP1→GRP2 downgrade-attack policy *(security reviewer)*

How long do we support `GRP1:` wires after GRP2 ships?

[`04-migration-plan.md`](04-migration-plan.md) Phase 2 now includes a `min_wire_version` field on envelopes so receivers can reject GRP1 at GRP2-only key versions. But the wire-acceptance window — "we never delete GRP1 support" — also needs revisiting.

**Default recommendation**: **flag-day cutover after Phase 5.** Once `is_encrypted=true` is default-on and the cohort soak has completed, set all newly-generated key versions to `min_wire_version=2`. Old key versions remain `min_wire_version=1` indefinitely for historical decrypt. Result: there is no version-N envelope at which a GRP1 downgrade is accepted, but historical messages still decrypt.

**Decisions log**:
- **DECIDED 2026-05-18**: flag-day cutover after Phase 5 ships. All new key versions minted after the flip get `min_wire_version=2`; older versions stay at `1` for historical decrypt. The downgrade attack window closes at Phase 5 — receivers refuse any GRP1 wire framed against a v2-only envelope.

### OQ-12 — Multi-device sender signatures *(security reviewer)*

If a user has 3 devices each with their own Ed25519 identity, which signs?

**Default recommendation**: **the sending device signs with its own identity key.** Server delivers (sender_user_id, sender_device_id) as it already does for 1:1. Recipients fetch the (user, device) identity-key bundle if not cached. Server caches all of a user's device-identity public keys. This adds a column to `identity_keys` if not present already (likely is).

**Decisions log**:
- **DECIDED 2026-05-18**: per-device signature. The sending device signs with its own Ed25519 identity key; recipients fetch the `(user_id, device_id)` identity pubkey from existing per-device bundles. Combined with OQ-10's per-user envelopes this gives us per-user *confidentiality* but per-device *authenticity* — a stolen device can read group history (already true) but can't forge messages as another device of the same user.

### OQ-13 — Server-side audit log of rotations *(security reviewer)*

For incident response (detecting malicious admin downgrade attempts, abnormal rotation frequency).

**Default recommendation**: **yes, with a tight schema.** Add `group_key_rotations(id, conversation_id, triggered_by_user_id, triggered_by_event, key_version, completed_at, completed_by_user_id)`. Cheap, append-only, no GC. Visible to group admins in settings. Tracked as a separate ~1 day work item, not part of the migration plan core.

**Decisions log**:
- **DECIDED 2026-05-18**: yes, ship the `group_key_rotations` table with the recommended schema. Visible to group admins in settings under "Encryption activity". Append-only, no GC. ~1 day work, tracked as a separate PR (not blocking Phase 2 core).

### OQ-14 — OS-upgrade key durability *(security reviewer)*

macOS Keychain has eaten keys across major-version upgrades historically. Android Keystore has migration bugs across vendor OEMs.

**Default recommendation**: **document, don't engineer around.** The 1:1 stack already handles "keys missing on first launch" via key regeneration + the "previous encrypted messages cannot be decrypted" snackbar. Group recovery uses the same machinery — admin re-triggers a rotation, recipient gets a new envelope. Add an item to release-checklist: test on macOS-N+1 / Android-N+1 betas before each major OS release.

**Decisions log**:
- **DECIDED 2026-05-18**: document, don't engineer. Existing key-regeneration machinery handles the user-facing case. Follow-up: add a release-checklist item to test on macOS-N+1 / Android-N+1 betas before each major OS release. No cloud escrow / iCloud Keychain sync work this sprint.

## Removed from the original list

- **OQ-5 ("removed members keep historical access")** was an industry-standard documentation item, not a decision. Kept in the list above for completeness but treated as pre-answered.
- **OQ-8 ("lock icon vs badge vs side-stripe")** was a UI decision, not a crypto decision. Default-answered above; UI/UX team can override.

---

## When this file gets touched

- **Before any code lands in Phase 2**: ~~OQ-1, OQ-11, OQ-12~~ — all DECIDED 2026-05-18.
- **Before Phase 3 lands**: ~~OQ-2, OQ-10~~ — all DECIDED 2026-05-18. ~~OQ-13~~ DECIDED.
- **Before Phase 5 lands**: ~~OQ-3, OQ-4, OQ-6, OQ-9~~ — all DECIDED 2026-05-18. ~~OQ-14~~ DECIDED — release-checklist follow-up filed below.
- **Deferred**: OQ-7 (post-P2-2) is the only outstanding item; it's an engineering decision, not a product one.

If you DECIDE an item, edit the corresponding `Decisions log` line in-place. Do not delete the question. Future maintainers reading this six months from now should see both the question and the answer.

## Follow-ups created by these decisions

- `docs/PRIVACY.md` should state: (a) removed members retain past message access; (b) encryption is one-way per group, cannot be downgraded; (c) plaintext groups cannot be retro-encrypted (OQ-4 limitation).
- Release-checklist gains an item: smoke-test crypto on the next major iOS/macOS/Android beta before each release branches (OQ-14).
- `group_key_rotations` audit log table (OQ-13) tracked as a separate PR, not blocking Phase 2 core.
- Phase 2B (GRP2 client packer/unpacker) is now unblocked; Phase 2 wire format = `GRP2:` prefix + version byte + nonce + ciphertext + tag + Ed25519 sender signature (per-device key).
- Phase 5 default-on flip is **immediate after Phase 4 ships** (OQ-3 override of the recommended 2-week soak). The rollback flag in `04-migration-plan.md` is the safety net.

## Decisions summary (2026-05-18)

| OQ | Decision |
|----|----------|
| OQ-1 | Ship the per-message Ed25519 sender signature |
| OQ-2 | Target <50 members → Sender Keys protocol |
| OQ-3 | Default-on flips immediately after Phase 4 ships (no 2-week soak) |
| OQ-4 | Plaintext-group migration is out of scope |
| OQ-5 | Removed members retain past message access |
| OQ-6 | Generic-only push notification on all platforms |
| OQ-7 | Deferred until P2-2 (wire-compat harness) lands |
| OQ-8 | Lock icon in group header (+ settings detail) |
| OQ-9 | Encryption is one-way; no admin downgrade |
| OQ-10 | Per-user envelopes (status quo) |
| OQ-11 | Flag-day cutover after Phase 5 ships |
| OQ-12 | Per-device sender signatures |
| OQ-13 | Ship `group_key_rotations` audit log table |
| OQ-14 | Document OS-upgrade behaviour; no engineering work |
