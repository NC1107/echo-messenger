import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';

void main() {
  group('GroupCryptoService', () {
    test('generateGroupKey returns 32 bytes base64-encoded', () {
      final key = GroupCryptoService.generateGroupKey();
      final decoded = base64Decode(key);
      expect(decoded.length, equals(32));
    });

    test('generateGroupKey produces unique keys', () {
      final key1 = GroupCryptoService.generateGroupKey();
      final key2 = GroupCryptoService.generateGroupKey();
      expect(key1, isNot(equals(key2)));
    });

    test('encrypt/decrypt roundtrip succeeds', () async {
      final key = GroupCryptoService.generateGroupKey();
      const plaintext = 'Hello, encrypted group!';

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );

      // Encrypted output should start with prefix
      expect(encrypted.startsWith(groupEncryptedPrefix), isTrue);

      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, equals(plaintext));
    });

    test('encrypt/decrypt with unicode content', () async {
      final key = GroupCryptoService.generateGroupKey();
      const plaintext = 'Hello world! Special chars: @#\$%^&*()';

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, equals(plaintext));
    });

    test('encrypt/decrypt with empty string', () async {
      final key = GroupCryptoService.generateGroupKey();
      const plaintext = '';

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, equals(plaintext));
    });

    test(
      'same plaintext produces different ciphertext (random nonce)',
      () async {
        final key = GroupCryptoService.generateGroupKey();
        const plaintext = 'Test message';

        final enc1 = await GroupCryptoService.encryptGroupMessage(
          plaintext,
          key,
        );
        final enc2 = await GroupCryptoService.encryptGroupMessage(
          plaintext,
          key,
        );

        // Different nonce -> different ciphertext
        expect(enc1, isNot(equals(enc2)));

        // Both should decrypt to the same plaintext
        final dec1 = await GroupCryptoService.decryptGroupMessage(enc1, key);
        final dec2 = await GroupCryptoService.decryptGroupMessage(enc2, key);
        expect(dec1, equals(plaintext));
        expect(dec2, equals(plaintext));
      },
    );

    test('decryption with wrong key fails', () async {
      final key1 = GroupCryptoService.generateGroupKey();
      final key2 = GroupCryptoService.generateGroupKey();
      const plaintext = 'Secret message';

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key1,
      );

      expect(
        () => GroupCryptoService.decryptGroupMessage(encrypted, key2),
        throwsA(isA<Object>()),
      );
    });

    test('decryption without prefix throws FormatException', () {
      final key = GroupCryptoService.generateGroupKey();

      expect(
        () => GroupCryptoService.decryptGroupMessage('not-prefixed', key),
        throwsA(isA<FormatException>()),
      );
    });

    test('decryption with truncated ciphertext throws', () {
      final key = GroupCryptoService.generateGroupKey();
      // Valid prefix but too short payload
      final shortPayload = '${groupEncryptedPrefix}AAAA';

      expect(
        () => GroupCryptoService.decryptGroupMessage(shortPayload, key),
        throwsA(isA<Object>()),
      );
    });

    test('long message encrypt/decrypt roundtrip', () async {
      final key = GroupCryptoService.generateGroupKey();
      // 10KB message
      final plaintext = 'A' * 10000;

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, equals(plaintext));
    });
  });

  group('GroupCryptoService.assertGroupKeyShape (audit P1-2)', () {
    final service = GroupCryptoService(serverUrl: 'http://example.invalid');

    test('accepts a freshly-generated 32-byte AES-256 key', () {
      final key = GroupCryptoService.generateGroupKey();
      // Should not throw.
      service.assertGroupKeyShape('conv-A', 0, key);
    });

    test('rejects an envelope-ciphertext-shaped candidate (the regression '
        'P1-2 closes)', () {
      // A typical AES-GCM-wrapped envelope is ~96 bytes: 12-byte nonce
      // + 32-byte key + 16-byte tag + ECDH ephemeral overhead. The
      // pre-fix fallback silently cached this as if it were the key.
      final envelopeShapedBlob = base64Encode(List<int>.filled(96, 0));
      expect(
        () => service.assertGroupKeyShape('conv-A', 5, envelopeShapedBlob),
        throwsA(
          isA<GroupEnvelopeUnwrapException>()
              .having((e) => e.conversationId, 'conv', 'conv-A')
              .having((e) => e.keyVersion, 'version', 5)
              .having((e) => e.reason, 'reason', contains('wrong length')),
        ),
      );
    });

    test('rejects a too-short candidate (< 32 bytes)', () {
      final shortBlob = base64Encode(List<int>.filled(16, 0));
      expect(
        () => service.assertGroupKeyShape('conv-A', 1, shortBlob),
        throwsA(isA<GroupEnvelopeUnwrapException>()),
      );
    });

    test('rejects a non-base64 candidate', () {
      expect(
        () => service.assertGroupKeyShape('conv-A', 1, 'not!valid!base64!'),
        throwsA(
          isA<GroupEnvelopeUnwrapException>().having(
            (e) => e.reason,
            'reason',
            contains('valid base64'),
          ),
        ),
      );
    });

    test('GroupEnvelopeUnwrapException.toString includes context', () {
      const exc = GroupEnvelopeUnwrapException('conv-X', 7, 'bad shape');
      final s = exc.toString();
      expect(s, contains('conv-X'));
      expect(s, contains('version=7'));
      expect(s, contains('bad shape'));
    });
  });
}
