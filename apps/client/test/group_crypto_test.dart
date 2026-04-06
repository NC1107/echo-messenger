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

    test('decryption without prefix throws FormatException', () async {
      final key = GroupCryptoService.generateGroupKey();

      expect(
        () => GroupCryptoService.decryptGroupMessage('not-prefixed', key),
        throwsA(isA<FormatException>()),
      );
    });

    test('decryption with truncated ciphertext throws', () async {
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
}
