/// Cross-implementation wire-compat test for the GRP2 group wire format.
///
/// Loads the same golden vectors as the Rust reference test in
/// `core/rust-core/tests/wire_compat.rs` and runs them through the Dart
/// production [GroupCryptoService] (via the test-only
/// [GroupCryptoService.packGrp2WithNonce] seam — see the constructor
/// docs there). Asserts byte-for-byte agreement with the recorded
/// `expected_wire_with_prefix` + `expected_signature_b64`.
///
/// If a vector fails, do NOT regenerate the goldens to make tests pass.
/// A divergence here is a real wire-format finding: both impls must
/// agree, or production messages from one client cannot be decrypted on
/// the other. See `tests/wire_compat/README.md`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';

class _Vector {
  final String name;
  final String description;
  final String groupKeyB64;
  final String conversationIdB64;
  final String messageIdB64;
  final String nonceB64;
  final String signingSeedB64;
  final String verifyKeyB64;
  final String plaintextUtf8;
  final String expectedWireWithPrefix;
  final String expectedSignatureB64;

  _Vector.fromJson(Map<String, dynamic> j)
    : name = j['name'] as String,
      description = j['description'] as String,
      groupKeyB64 = j['group_key_b64'] as String,
      conversationIdB64 = j['conversation_id_b64'] as String,
      messageIdB64 = j['message_id_b64'] as String,
      nonceB64 = j['nonce_b64'] as String,
      signingSeedB64 = j['signing_seed_b64'] as String,
      verifyKeyB64 = j['verify_key_b64'] as String,
      plaintextUtf8 = j['plaintext_utf8'] as String,
      expectedWireWithPrefix = j['expected_wire_with_prefix'] as String,
      expectedSignatureB64 = j['expected_signature_b64'] as String;
}

List<_Vector> _loadVectors() {
  // Flutter unit tests run with Directory.current = apps/client. Vectors
  // live at the repo root under tests/wire_compat/vectors/. Walk up two
  // levels.
  final pkgRoot = Directory.current.path;
  final vectorsDir = Directory(
    [
      pkgRoot,
      '..',
      '..',
      'tests',
      'wire_compat',
      'vectors',
    ].join(Platform.pathSeparator),
  );
  if (!vectorsDir.existsSync()) {
    throw StateError(
      'wire-compat vectors directory not found at ${vectorsDir.path}. '
      'Run the Rust generator: '
      'cargo run -p echo-core --example gen_grp2_vectors',
    );
  }
  final files =
      vectorsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files
      .map(
        (f) => _Vector.fromJson(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
        ),
      )
      .toList();
}

Uint8List _b64(String s) => Uint8List.fromList(base64Decode(s));

void main() {
  group('GRP2 cross-impl wire-compat (audit P2-2)', () {
    late List<_Vector> vectors;

    setUpAll(() {
      vectors = _loadVectors();
    });

    test('at least 5 vectors are present', () {
      expect(
        vectors.length,
        greaterThanOrEqualTo(5),
        reason:
            'expected at least 5 golden vectors; see tests/wire_compat/README.md',
      );
    });

    test('Dart pack matches every golden byte-for-byte', () async {
      for (final v in vectors) {
        final seed = _b64(v.signingSeedB64);
        final verifyExpected = _b64(v.verifyKeyB64);

        final keyPair = await Ed25519().newKeyPairFromSeed(seed);
        // Sanity: the Dart-derived verify key MUST match the seed-derived
        // verify key recorded by the Rust generator. Divergence here means
        // the two impls disagree on Ed25519 seed handling, which would
        // break every signed message regardless of wire-format correctness.
        final pub = await keyPair.extractPublicKey();
        expect(
          pub.bytes,
          orderedEquals(verifyExpected),
          reason:
              'vector ${v.name}: Ed25519 verify key derived from seed '
              'diverges between Dart and Rust',
        );

        final wire = await GroupCryptoService.packGrp2WithNonce(
          plaintext: v.plaintextUtf8,
          keyBase64: v.groupKeyB64,
          conversationIdBytes: _b64(v.conversationIdB64),
          messageIdBytes: _b64(v.messageIdB64),
          senderSigningKey: keyPair,
          nonce: _b64(v.nonceB64),
        );

        expect(
          wire,
          equals(v.expectedWireWithPrefix),
          reason:
              'vector ${v.name} (${v.description}): Dart wire output '
              'diverged from golden. If this is intentional, the GRP2 '
              'version byte must bump and goldens be regenerated. '
              'See tests/wire_compat/README.md.',
        );

        // Pull the signature off the tail and assert it independently
        // for a clearer error when only the signature diverges.
        final wireBytes = base64Decode(
          wire.substring(groupEncryptedPrefixV2.length),
        );
        final sigBytes = wireBytes.sublist(wireBytes.length - 64);
        expect(
          base64Encode(sigBytes),
          equals(v.expectedSignatureB64),
          reason:
              'vector ${v.name}: Ed25519 signature diverged from golden '
              '(wire matched up to the tail).',
        );
      }
    });

    test('Dart unpack accepts every golden wire', () async {
      for (final v in vectors) {
        final verifyKey = SimplePublicKey(
          _b64(v.verifyKeyB64),
          type: KeyPairType.ed25519,
        );
        final plaintext =
            await GroupCryptoService.verifyAndDecryptGroupMessageV2(
              ciphertextWithPrefix: v.expectedWireWithPrefix,
              keyBase64: v.groupKeyB64,
              expectedConversationIdBytes: _b64(v.conversationIdB64),
              expectedMessageIdBytes: _b64(v.messageIdB64),
              senderVerifyKey: verifyKey,
            );
        expect(
          plaintext,
          equals(v.plaintextUtf8),
          reason: 'vector ${v.name}: decrypted plaintext diverged from golden',
        );
      }
    });
  });
}
