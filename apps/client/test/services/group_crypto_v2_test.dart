/// Audit Phase 2B acceptance tests for the GRP2 wire format.
///
/// The GRP2 wire carries an Ed25519 sender signature so any current OR
/// former member with the group key cannot forge as another member
/// (audit OQ-1, OQ-12). The signature binds:
///
///   version_byte || conversation_id(16) || message_id(16)
///                || nonce(12) || ciphertext || tag(16)
///
/// These tests cover the static encrypt + verify-and-decrypt primitives
/// in isolation. Production WS wire-up (mint the message UUID client-
/// side, plumb the conv/msg context through the receive frame) lives
/// in Phase 2C.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';

void main() {
  group('GRP2 encrypt + verifyAndDecrypt (audit OQ-1, OQ-11, OQ-12)', () {
    late SimpleKeyPair signingKey;
    late SimplePublicKey verifyKey;
    late String keyBase64;
    late Uint8List convId;
    late Uint8List msgId;

    setUp(() async {
      // Per-device Ed25519 signing key. OQ-12 picks "sending device
      // signs with its own identity key"; in the real client this
      // would be CryptoService._signingKeyPair, but the static method
      // accepts any Ed25519 keypair so tests can pin one.
      signingKey = await Ed25519().newKeyPair();
      verifyKey = await signingKey.extractPublicKey();
      keyBase64 = GroupCryptoService.generateGroupKey();
      // Conversation + message IDs as raw 16-byte UUIDs.
      convId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      msgId = Uint8List.fromList(List<int>.generate(16, (i) => i + 100));
    });

    test('happy path: encrypt + verify-and-decrypt round-trips', () async {
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'hello signed group',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );

      expect(
        wire.startsWith(groupEncryptedPrefixV2),
        isTrue,
        reason: 'wire must use GRP2: prefix',
      );

      final out = await GroupCryptoService.verifyAndDecryptGroupMessageV2(
        ciphertextWithPrefix: wire,
        keyBase64: keyBase64,
        expectedConversationIdBytes: convId,
        expectedMessageIdBytes: msgId,
        senderVerifyKey: verifyKey,
      );
      expect(out, 'hello signed group');
    });

    test('wire format: version byte + nonce + ct + tag + sig', () async {
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'sized',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );
      final bytes = base64Decode(wire.substring(groupEncryptedPrefixV2.length));
      // version(1) + nonce(12) + ct(5) + tag(16) + sig(64) = 98 bytes.
      expect(bytes.length, 1 + 12 + 5 + 16 + 64);
      expect(bytes[0], groupEncryptedV2Version);
    });

    test('signature failure: verifying with a DIFFERENT sender pubkey '
        'throws GroupSenderSignatureException', () async {
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'forge me',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );
      // A different device's public key.
      final wrongPair = await Ed25519().newKeyPair();
      final wrongPub = await wrongPair.extractPublicKey();

      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: wire,
          keyBase64: keyBase64,
          expectedConversationIdBytes: convId,
          expectedMessageIdBytes: msgId,
          senderVerifyKey: wrongPub,
        ),
        throwsA(isA<GroupSenderSignatureException>()),
      );
    });

    test('signature failure: verifying with the WRONG conversation_id '
        'throws GroupSenderSignatureException', () async {
      // The audit's "no cross-conversation replay" property: a message
      // signed for conv A cannot be replayed by a hostile server into
      // conv B even if both groups happen to share a key version.
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'conv-bound',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );
      final differentConv = Uint8List.fromList(
        List<int>.generate(16, (i) => i + 200),
      );

      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: wire,
          keyBase64: keyBase64,
          expectedConversationIdBytes: differentConv,
          expectedMessageIdBytes: msgId,
          senderVerifyKey: verifyKey,
        ),
        throwsA(isA<GroupSenderSignatureException>()),
      );
    });

    test('signature failure: verifying with the WRONG message_id '
        'throws GroupSenderSignatureException', () async {
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'msg-bound',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );
      final differentMsgId = Uint8List.fromList(
        List<int>.generate(16, (i) => i + 50),
      );

      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: wire,
          keyBase64: keyBase64,
          expectedConversationIdBytes: convId,
          expectedMessageIdBytes: differentMsgId,
          senderVerifyKey: verifyKey,
        ),
        throwsA(isA<GroupSenderSignatureException>()),
      );
    });

    test('AEAD failure: WRONG group key fails on decrypt (signature passes '
        'because the same key wasn\'t signed over)', () async {
      // Signature is independent of the symmetric key — it covers the
      // ciphertext, which a wrong key produces but cannot decrypt. So
      // signature verify succeeds, AEAD decrypt fails.
      final wire = await GroupCryptoService.encryptGroupMessageV2(
        plaintext: 'data',
        keyBase64: keyBase64,
        conversationIdBytes: convId,
        messageIdBytes: msgId,
        senderSigningKey: signingKey,
      );
      final wrongKey = GroupCryptoService.generateGroupKey();

      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: wire,
          keyBase64: wrongKey,
          expectedConversationIdBytes: convId,
          expectedMessageIdBytes: msgId,
          senderVerifyKey: verifyKey,
        ),
        throwsA(isNot(isA<GroupSenderSignatureException>())),
        reason:
            'AEAD failure should NOT be reported as a signature failure '
            '— the two error classes drive different UI placeholders',
      );
    });

    test(
      'tampered ciphertext fails signature verify (sig covers ct + tag)',
      () async {
        final wire = await GroupCryptoService.encryptGroupMessageV2(
          plaintext: 'pristine',
          keyBase64: keyBase64,
          conversationIdBytes: convId,
          messageIdBytes: msgId,
          senderSigningKey: signingKey,
        );
        // Flip a byte in the ciphertext region.
        final bytes = base64Decode(
          wire.substring(groupEncryptedPrefixV2.length),
        );
        // ct starts at offset 13 (version + nonce). Flip the first ct byte.
        bytes[13] ^= 0xFF;
        final tampered = '$groupEncryptedPrefixV2${base64Encode(bytes)}';

        await expectLater(
          GroupCryptoService.verifyAndDecryptGroupMessageV2(
            ciphertextWithPrefix: tampered,
            keyBase64: keyBase64,
            expectedConversationIdBytes: convId,
            expectedMessageIdBytes: msgId,
            senderVerifyKey: verifyKey,
          ),
          throwsA(isA<GroupSenderSignatureException>()),
        );
      },
    );

    test('rejects GRP1: prefix (missing GRP2 marker)', () async {
      final v1Wire = await GroupCryptoService.encryptGroupMessage(
        'legacy',
        keyBase64,
      );
      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: v1Wire,
          keyBase64: keyBase64,
          expectedConversationIdBytes: convId,
          expectedMessageIdBytes: msgId,
          senderVerifyKey: verifyKey,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects truncated GRP2 wire', () async {
      // 50 bytes of zeros — well below the 93-byte minimum.
      final shortWire =
          '$groupEncryptedPrefixV2${base64Encode(List<int>.filled(50, 0))}';
      await expectLater(
        GroupCryptoService.verifyAndDecryptGroupMessageV2(
          ciphertextWithPrefix: shortWire,
          keyBase64: keyBase64,
          expectedConversationIdBytes: convId,
          expectedMessageIdBytes: msgId,
          senderVerifyKey: verifyKey,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'rejects an unknown future GRP2 revision (forward-compat fail-loud)',
      () async {
        // Hand-craft a wire with a version byte the receiver doesn't know.
        final fake = Uint8List(1 + 12 + 16 + 64);
        fake[0] = 0xFF; // unknown future revision
        final wire = '$groupEncryptedPrefixV2${base64Encode(fake)}';
        await expectLater(
          GroupCryptoService.verifyAndDecryptGroupMessageV2(
            ciphertextWithPrefix: wire,
            keyBase64: keyBase64,
            expectedConversationIdBytes: convId,
            expectedMessageIdBytes: msgId,
            senderVerifyKey: verifyKey,
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('signature payload helper validates UUID lengths', () async {
      // 8-byte "uuid" should bounce.
      final tooShort = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      await expectLater(
        GroupCryptoService.encryptGroupMessageV2(
          plaintext: 'x',
          keyBase64: keyBase64,
          conversationIdBytes: tooShort,
          messageIdBytes: msgId,
          senderSigningKey: signingKey,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('GroupSenderSignatureException.toString includes the reason', () {
      const exc = GroupSenderSignatureException('bad sig');
      expect(exc.toString(), contains('bad sig'));
    });
  });
}
