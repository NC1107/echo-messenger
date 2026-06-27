/// Cross-implementation wire-compat test for the 1:1 X3DH + Double-Ratchet
/// primitives (audit P2-2).
///
/// Loads the SAME golden vectors as the Rust reference test in
/// `core/rust-core/tests/wire_compat_1to1.rs` (repo root
/// `tests/wire_compat/1to1/`) and runs them through the Dart production impl
/// (`signal_x3dh.dart` + `signal_protocol.dart`). Asserts:
///  - X3DH `respond` derives the recorded shared secret (DH order + the
///    `EchoSignalX3DH` HKDF label must match Rust), and
///  - `MessageHeader` serializes to the recorded 40-byte wire and parses back.
///
/// A divergence here is a real finding: if the Dart and Rust 1:1 wire/KDF
/// disagree, production messages from one platform can't be decrypted on
/// another. Do NOT regenerate goldens to make tests pass.
/// See `tests/wire_compat/README.md`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:echo_app/src/services/signal_protocol.dart';
import 'package:echo_app/src/services/signal_x3dh.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _loadVectors() {
  // Flutter unit tests run with Directory.current = apps/client; vectors live
  // at the repo root under tests/wire_compat/1to1/. Walk up two levels.
  final dir = Directory(
    [
      Directory.current.path,
      '..',
      '..',
      'tests',
      'wire_compat',
      '1to1',
    ].join(Platform.pathSeparator),
  );
  if (!dir.existsSync()) {
    throw StateError('1:1 wire-compat vectors not found at ${dir.path}');
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files
      .map((f) => json.decode(f.readAsStringSync()) as Map<String, dynamic>)
      .toList();
}

Uint8List _b64(String s) => base64.decode(s);

final _x25519 = X25519();

/// Build an X25519 [SimpleKeyPair] from a pinned 32-byte private seed.
Future<SimpleKeyPair> _kpFromSeed(String b64) =>
    _x25519.newKeyPairFromSeed(_b64(b64));

/// Derive the X25519 public key for a pinned private seed.
Future<SimplePublicKey> _pubFromSeed(String b64) async =>
    (await _kpFromSeed(b64)).extractPublicKey();

void main() {
  final vectors = _loadVectors();

  test('1:1 golden vectors are present', () {
    expect(
      vectors,
      isNotEmpty,
      reason: 'no vectors loaded from tests/wire_compat/1to1',
    );
    expect(
      vectors.where((v) => v['kind'] == 'x3dh_respond'),
      isNotEmpty,
      reason: 'expected at least one x3dh_respond vector',
    );
    expect(
      vectors.where((v) => v['kind'] == 'message_header'),
      isNotEmpty,
      reason: 'expected at least one message_header vector',
    );
  });

  group('MessageHeader wire layout', () {
    for (final v in vectors.where((v) => v['kind'] == 'message_header')) {
      test(v['name'] as String, () {
        final header = MessageHeader(
          ratchetPublicKey: _b64(v['ratchet_public_key_b64'] as String),
          prevChainLength: v['prev_chain_length'] as int,
          messageNumber: v['message_number'] as int,
        );
        final expected = _b64(v['expected_header_b64'] as String);
        expect(
          header.serialize(),
          orderedEquals(expected),
          reason: 'serialize mismatch vs Rust golden',
        );
        // Round-trip: recorded bytes parse back to the same fields.
        final parsed = MessageHeader.deserialize(expected);
        expect(parsed.ratchetPublicKey, orderedEquals(header.ratchetPublicKey));
        expect(parsed.prevChainLength, header.prevChainLength);
        expect(parsed.messageNumber, header.messageNumber);
      });
    }
  });

  group('X3DH respond shared secret', () {
    for (final v in vectors.where((v) => v['kind'] == 'x3dh_respond')) {
      test(v['name'] as String, () async {
        final expected = v['expected_shared_secret_b64'] as String;
        expect(
          expected,
          isNot('GENERATE'),
          reason:
              'vector still has placeholder secret — run the Rust generator',
        );

        final bobIdentity = await _kpFromSeed(
          v['bob_identity_private_b64'] as String,
        );
        final bobSpk = await _kpFromSeed(
          v['bob_signed_prekey_private_b64'] as String,
        );
        final otpB64 = v['bob_one_time_prekey_private_b64'] as String?;
        final bobOtp = otpB64 == null ? null : await _kpFromSeed(otpB64);
        // Alice's publics are derived from her pinned privates (same as Rust).
        final aliceIdPub = await _pubFromSeed(
          v['alice_identity_private_b64'] as String,
        );
        final aliceEphPub = await _pubFromSeed(
          v['alice_ephemeral_private_b64'] as String,
        );

        final secret = await X3DH.respond(
          bobIdentity: bobIdentity,
          bobSignedPrekey: bobSpk,
          bobOneTimePrekey: bobOtp,
          aliceIdentityKey: aliceIdPub,
          aliceEphemeralKey: aliceEphPub,
        );

        expect(
          base64.encode(secret),
          expected,
          reason:
              'X3DH respond shared-secret mismatch vs Rust golden — a real '
              'cross-impl divergence (DH order or HKDF label drift)',
        );
      });
    }
  });
}
