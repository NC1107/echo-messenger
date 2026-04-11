import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';

void main() {
  group('groupEncryptedPrefix', () {
    test('is GRP1:', () {
      expect(groupEncryptedPrefix, 'GRP1:');
    });
  });

  group('GroupCryptoService.generateGroupKey', () {
    test('generates a non-empty base64 key', () {
      final key = GroupCryptoService.generateGroupKey();
      expect(key, isNotEmpty);
      expect(key.length, greaterThan(20)); // 32 bytes = 44 chars base64
    });

    test('generates different keys each time', () {
      final key1 = GroupCryptoService.generateGroupKey();
      final key2 = GroupCryptoService.generateGroupKey();
      expect(key1, isNot(equals(key2)));
    });
  });

  group('GroupCryptoService encrypt/decrypt', () {
    test('encrypts and decrypts a message', () async {
      final key = GroupCryptoService.generateGroupKey();
      const plaintext = 'Hello, group!';

      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      expect(encrypted, startsWith(groupEncryptedPrefix));

      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, plaintext);
    });

    test('encrypted output has prefix', () async {
      final key = GroupCryptoService.generateGroupKey();
      final encrypted = await GroupCryptoService.encryptGroupMessage(
        'test',
        key,
      );
      expect(encrypted.startsWith('GRP1:'), isTrue);
    });

    test('different messages produce different ciphertexts', () async {
      final key = GroupCryptoService.generateGroupKey();
      final enc1 = await GroupCryptoService.encryptGroupMessage(
        'message 1',
        key,
      );
      final enc2 = await GroupCryptoService.encryptGroupMessage(
        'message 2',
        key,
      );
      expect(enc1, isNot(equals(enc2)));
    });

    test(
      'same plaintext produces different ciphertexts (random nonce)',
      () async {
        final key = GroupCryptoService.generateGroupKey();
        final enc1 = await GroupCryptoService.encryptGroupMessage(
          'same text',
          key,
        );
        final enc2 = await GroupCryptoService.encryptGroupMessage(
          'same text',
          key,
        );
        expect(enc1, isNot(equals(enc2)));
      },
    );

    test('decryption with wrong key fails', () async {
      final key1 = GroupCryptoService.generateGroupKey();
      final key2 = GroupCryptoService.generateGroupKey();
      final encrypted = await GroupCryptoService.encryptGroupMessage(
        'secret',
        key1,
      );

      expect(
        () => GroupCryptoService.decryptGroupMessage(encrypted, key2),
        throwsA(isA<Exception>()),
      );
    });

    test('decryption without prefix throws FormatException', () async {
      final key = GroupCryptoService.generateGroupKey();
      expect(
        () => GroupCryptoService.decryptGroupMessage('no-prefix-data', key),
        throwsA(isA<FormatException>()),
      );
    });

    test('handles empty plaintext', () async {
      final key = GroupCryptoService.generateGroupKey();
      final encrypted = await GroupCryptoService.encryptGroupMessage('', key);
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, '');
    });

    test('handles unicode plaintext', () async {
      final key = GroupCryptoService.generateGroupKey();
      const plaintext = 'Hello! Emoji test: \u{1F600}\u{1F389}\u{1F680}';
      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, plaintext);
    });

    test('handles long plaintext', () async {
      final key = GroupCryptoService.generateGroupKey();
      final plaintext = 'A' * 10000;
      final encrypted = await GroupCryptoService.encryptGroupMessage(
        plaintext,
        key,
      );
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        encrypted,
        key,
      );
      expect(decrypted, plaintext);
    });
  });

  group('GroupCryptoService construction', () {
    test('stores server URL', () {
      final service = GroupCryptoService(serverUrl: 'http://localhost:8080');
      expect(service.serverUrl, 'http://localhost:8080');
    });

    test('markUnencrypted/markEncrypted toggle tracking', () {
      final service = GroupCryptoService(serverUrl: 'http://localhost');
      // No public API to check, but these should not throw
      service.markUnencrypted('conv-1');
      service.markEncrypted('conv-1');
    });

    test('setToken accepts a token', () {
      final service = GroupCryptoService(serverUrl: 'http://localhost');
      service.setToken('test-token');
    });
  });
}
