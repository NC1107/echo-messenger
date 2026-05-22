# Cross-implementation wire-compat tests

The Echo crypto layer has [two implementations of the GRP2 group wire
format][audit-doc]: a Rust reference in `core/rust-core/src/signal/grp2.rs`
and the production Dart impl in
`apps/client/lib/src/services/group_crypto_service.dart`. They share an
idea, not code. This directory's golden vectors are the forcing function
that catches the day one of them silently drifts from the other.

[audit-doc]: ../../docs/crypto-audit/05-rust-core-vs-dart.md

## What the goldens prove

Every JSON file in `vectors/` records a fully-specified GRP2 pack:

- Inputs: 32-byte group key, raw 16-byte conversation + message UUIDs,
  pinned 12-byte AES-GCM nonce, 32-byte Ed25519 signing-key seed, and
  the UTF-8 plaintext.
- Outputs: the textual `GRP2:` wire frame (with the leading prefix), the
  64-byte Ed25519 signature, and the derived 32-byte verify key.

Both implementations consume the same JSON. Each language's test runs
its production packer with the pinned nonce + seed and asserts the wire
bytes match the recorded `expected_wire_with_prefix` byte-for-byte. The
Dart side additionally asserts that the seed-derived verify key matches
Rust's — divergence there means Ed25519 seed handling disagrees and no
signed message would round-trip.

Coverage targets (one vector per row):

| File | What it stresses |
|------|------------------|
| `01-empty-plaintext.json` | Minimum wire size: version + nonce + tag + sig, no ciphertext. |
| `02-single-byte.json` | Smallest non-empty payload. |
| `03-short-ascii.json` | The common chat case. |
| `04-utf8-emoji.json` | Multi-byte UTF-8 + emoji — catches `utf8.encode` vs `str::as_bytes` mismatches. |
| `05-aes-block-boundary.json` | Plaintext exactly 16 bytes (one AES block). |
| `06-multi-block.json` | ~5 AES blocks — catches CTR mode bugs that only fire after the first counter increment. |
| `07-distinct-keys-ids.json` | Every input field a distinct byte pattern; guards against field-swap bugs. |
| `08-newline-and-null.json` | Embedded NUL + newline; guards against C-string assumptions. |
| `09-largish.json` | ~1 KiB payload; catches short-buffer assumptions. |

## Running

```bash
# Rust side
cargo test -p echo-core --test wire_compat

# Dart side
cd apps/client && flutter test test/services/group_crypto_wire_compat_test.dart
```

Both must pass on identical JSON inputs. If only one side passes the
implementations have diverged — see "Workflow on failure" below.

## Regenerating goldens

The vectors are produced by a Rust binary that is the **single source
of truth** for the expected output. You only regenerate them when the
wire format intentionally changes:

```bash
cargo run -p echo-core --example gen_grp2_vectors
git add tests/wire_compat/vectors/
```

A wire-format change is a deliberate breaking change to the protocol.
The required process is:

1. Bump the GRP2 revision byte (`GRP2_VERSION` in both impls). The
   textual `GRP2:` prefix never changes; the revision byte after base64
   decoding is what tells receivers which layout to expect.
2. Update both `core/rust-core/src/signal/grp2.rs` and
   `apps/client/lib/src/services/group_crypto_service.dart` so they
   produce the new layout.
3. Update the generator (`core/rust-core/examples/gen_grp2_vectors.rs`)
   if new fields need to be added to the goldens.
4. Run the generator. Commit the regenerated `vectors/*.json` in the
   SAME commit as the format change. Reviewers can then diff the JSON
   to confirm the change is what you described.
5. Bump `min_wire_version` on encrypted-group envelopes so receivers
   downgrade-protect themselves (see Phase 2A notes in
   `group_crypto_service.dart`).

**Do NOT regenerate goldens to make a failing test pass on a release
branch.** A green local run does not mean the impls agree; it means
both impls agree on whatever Rust happened to produce when the
generator was last run. The goldens only have value if they outlive
casual edits.

## Workflow on failure

When `cargo test --test wire_compat` and `flutter test ... wire_compat`
disagree:

1. **Stop.** Do not edit goldens, do not skip the test.
2. Identify which language's output diverges from the recorded golden.
   The Rust test failure message names the vector and the Dart test
   message names the field; together they isolate the divergence.
3. Read both implementations of the divergent step. Common suspects:
   - AES-GCM tag concatenation ordering (`ct || tag` vs `tag || ct`).
   - UUID byte order (raw 16 bytes vs hyphenated string).
   - Signature payload field ordering (the design doc and impl have
     drifted here before — impl is the source of truth).
   - Ed25519 seed vs expanded key handling.
4. Fix the buggy impl. The golden is correct unless you can show the
   generator itself is wrong (in which case fix the generator, then
   regenerate).
5. Land the fix in the same PR as a regression vector that exercises
   the specific case.

If the disagreement is "we intentionally want to change the format,"
that is not a wire-compat failure — that is a deliberate version bump.
Follow "Regenerating goldens" above instead.

## Why this exists

`docs/crypto-audit/05-rust-core-vs-dart.md` writes up the underlying
two-implementation problem. The short version: Echo ships a Rust
reference and a Dart re-implementation of the same crypto primitives,
the FFI bridge that would have unified them never landed, and the most
likely failure mode is silent spec drift between them. These vectors
are the cheap, language-agnostic interlock that makes drift loud.
