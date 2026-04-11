import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/crypto_utils.dart';

void main() {
  group('looksEncrypted', () {
    test('returns false for short strings', () {
      expect(looksEncrypted('hello'), isFalse);
      expect(looksEncrypted(''), isFalse);
      expect(looksEncrypted('abc'), isFalse);
      expect(looksEncrypted('A' * 19), isFalse);
    });

    test('returns true for base64-like strings >= 20 chars', () {
      expect(looksEncrypted('A' * 20), isTrue);
      expect(looksEncrypted('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'), isTrue);
      expect(looksEncrypted('abc123+/ABCdef456789=='), isTrue);
    });

    test('returns false for plaintext with spaces', () {
      expect(looksEncrypted('Hello World this is a message'), isFalse);
    });

    test('returns false for plaintext with special characters', () {
      expect(looksEncrypted('Hey! How are you doing?'), isFalse);
    });

    test('returns true for realistic base64 ciphertext', () {
      // Simulated base64-encoded ciphertext
      expect(
        looksEncrypted('7AwBigYi1X5g8Nnf+qDkvC2YmJw3bZ0A2K/8hL0PQXE='),
        isTrue,
      );
    });

    test('returns false for messages with punctuation', () {
      expect(looksEncrypted('This is a test. It has periods!'), isFalse);
    });

    test('returns false for URLs', () {
      expect(looksEncrypted('https://example.com/path'), isFalse);
    });
  });
}
