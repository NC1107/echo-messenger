# 05 — Rust-core vs Dart: The Two-Implementation Problem

A crypto layer should have one implementation. We have two.

## Current state

- `core/rust-core/src/signal/**/*.rs` — a complete Signal Protocol implementation in Rust. Has its own tests. Used by Rust integration tests in `apps/server/tests/` to validate round-trip envelope shapes.
- `apps/client/lib/src/services/signal_*.dart` — a complete re-implementation in pure Dart. Used by the production Flutter client.

These do not share code. They share an idea.

CLAUDE.md "Known Limitations" #3 explains the history: the original plan was a Dart-side FFI bridge to the Rust implementation. The bridge never landed. The abandoned FFI transitive deps (`rusqlite`, `tokio-tungstenite`, `reqwest`, `tokio`, `futures-util`) have since been pruned from `core/rust-core/Cargo.toml`.

## Why this is a risk

| Failure mode | Cost |
|--------------|------|
| Spec divergence between Rust and Dart | Hard to catch without a cross-implementation interop test |
| Bug fixed in one, not the other | Server tests pass; client breaks (or vice versa) |
| Future contributor confused about which is canonical | Adds to the wrong one |
| Wire-format drift | Round-trip tests in Rust pass; production fails |

None of these failure modes are currently active — both implementations agree on the wire format and the Dart-side production code is the source of truth. But the *risk* is real and grows with every change to either side.

## Options

### Option A — Keep both, formalise the contract

Treat Rust as the spec, Dart as the implementation. Add a "wire compatibility test" in Rust that loads test vectors emitted by Dart and decrypts them, and vice versa. Vectors live in a shared `testdata/` directory.

- **Pro**: cheap, lowest friction.
- **Con**: easy to forget when adding new wire shapes; spec drift still possible.

### Option B — Delete rust-core's Signal code

Stop pretending Rust is the reference. Delete `core/rust-core/src/signal/`. Server tests that need round-trip validation use the Dart binary in a subprocess (slow, ugly) or use a different language-agnostic reference (e.g. libsignal-protocol-c via FFI).

- **Pro**: zero ambiguity; one implementation.
- **Con**: loses the Rust-side integration tests that today validate the server's storage of ciphertext.

### Option C — Resurrect the FFI bridge

The original plan. Compile rust-core to a native lib + WASM, expose a thin C ABI, drive from Dart via `dart:ffi` (or `package:flutter_rust_bridge`). Dart deletes its re-implementation.

- **Pro**: one implementation, with the audit-friendlier language for crypto.
- **Con**: large engineering effort (estimate: 4–8 weeks calendar including web/WASM path), introduces a non-trivial new build surface (cross-compilation matrix, WASM toolchain), risk of regressions during the cutover. The whole reason we have a Dart re-implementation is that this turned out to be more work than the original plan budgeted.

### Option D — Adopt libsignal directly

Compile the official libsignal-client (Rust) with FFI bindings to Dart instead of maintaining our own Rust port. Better than C: this is the implementation Signal themselves run.

- **Pro**: out-of-the-box correctness, ongoing upstream security fixes.
- **Con**: libsignal-client's FFI surface is not friendly; Signal Foundation does not publish stable Dart bindings; you become responsible for keeping a fork building. Larger lift than Option C.

## Recommendation

**Option A short-term, evaluate B vs C later.**

Concretely, this sprint:
1. Add a `testdata/wire-vectors/` directory under `core/rust-core/`.
2. Each language-pair test loads a vector, decrypts, and asserts plaintext + ratchet state.
3. Dart tests under `apps/client/test/services/signal_*_compat_test.dart` that produce vectors; Rust tests under `core/rust-core/tests/wire_compat.rs` that consume them.
4. Run both in CI on the same PR.

This is the cheapest way to defend against future drift without committing to a multi-week migration. It also gives us a forcing function: if the Rust port ever stops being trivially maintainable, the broken compat test tells us *immediately* — and is also the point at which Option B (delete rust-core's Signal code) becomes defensible.

We **do not** recommend pursuing Option C / D now. Echo's product surface has bigger gaps; the Dart implementation is working in production; cutover risk on a crypto cutover is unacceptable while features are still landing.

## Tracking

File a meta-issue: "Crypto: one implementation, two languages — cross-impl wire-compat test in CI".
