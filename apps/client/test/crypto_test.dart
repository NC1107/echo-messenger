import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Cryptography package on Linux', () {
    test('X25519 key generation works', () async {
      final x25519 = X25519();
      final keyPair = await x25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      expect(publicKey.bytes.length, equals(32));
      debugPrint('X25519 public key: ${base64Encode(publicKey.bytes)}');
    });

    test('X25519 key exchange works', () async {
      final x25519 = X25519();
      final aliceKeyPair = await x25519.newKeyPair();
      final bobKeyPair = await x25519.newKeyPair();

      final alicePub = await aliceKeyPair.extractPublicKey();
      final bobPub = await bobKeyPair.extractPublicKey();

      final aliceShared = await x25519.sharedSecretKey(
        keyPair: aliceKeyPair,
        remotePublicKey: bobPub,
      );
      final bobShared = await x25519.sharedSecretKey(
        keyPair: bobKeyPair,
        remotePublicKey: alicePub,
      );

      final aliceBytes = await aliceShared.extractBytes();
      final bobBytes = await bobShared.extractBytes();
      expect(aliceBytes, equals(bobBytes));
      debugPrint('Shared secret: ${base64Encode(aliceBytes)}');
    });

    test('AES-GCM encrypt/decrypt works', () async {
      final aes = AesGcm.with256bits();
      final key = await aes.newSecretKey();
      final plaintext = utf8.encode('Hello, encrypted world!');

      final secretBox = await aes.encrypt(plaintext, secretKey: key);
      final decrypted = await aes.decrypt(secretBox, secretKey: key);

      expect(utf8.decode(decrypted), equals('Hello, encrypted world!'));
    });

    test('HKDF key derivation works', () async {
      final x25519 = X25519();
      final keyPair = await x25519.newKeyPair();
      final otherKeyPair = await x25519.newKeyPair();
      final otherPub = await otherKeyPair.extractPublicKey();

      final sharedSecret = await x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: otherPub,
      );

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final derivedKey = await hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: utf8.encode('EchoE2EE'),
        info: utf8.encode('echo-session-test'),
      );

      final bytes = await derivedKey.extractBytes();
      expect(bytes.length, equals(32));
      debugPrint('Derived key: ${base64Encode(bytes)}');
    });

    test('Full encrypt/decrypt flow (simulating CryptoService)', () async {
      final x25519 = X25519();
      final aes = AesGcm.with256bits();

      // Generate keypairs for alice and bob
      final aliceKP = await x25519.newKeyPair();
      final bobKP = await x25519.newKeyPair();
      final alicePub = await aliceKP.extractPublicKey();
      final bobPub = await bobKP.extractPublicKey();

      // Create canonical session info (sorted public keys)
      final alicePubB64 = base64Encode(alicePub.bytes);
      final bobPubB64 = base64Encode(bobPub.bytes);
      final sortedKeys = [alicePubB64, bobPubB64]..sort();
      final sessionInfo = 'echo-session-${sortedKeys[0]}-${sortedKeys[1]}';

      // DH + HKDF to derive shared key (alice's perspective)
      final aliceShared = await x25519.sharedSecretKey(
        keyPair: aliceKP,
        remotePublicKey: bobPub,
      );
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final aliceSessionKey = await hkdf.deriveKey(
        secretKey: aliceShared,
        nonce: utf8.encode('EchoE2EE'),
        info: utf8.encode(sessionInfo),
      );

      // Same from bob's perspective
      final bobShared = await x25519.sharedSecretKey(
        keyPair: bobKP,
        remotePublicKey: alicePub,
      );
      final bobSessionKey = await hkdf.deriveKey(
        secretKey: bobShared,
        nonce: utf8.encode('EchoE2EE'),
        info: utf8.encode(sessionInfo),
      );

      // Verify keys match
      final aliceKeyBytes = await aliceSessionKey.extractBytes();
      final bobKeyBytes = await bobSessionKey.extractBytes();
      expect(aliceKeyBytes, equals(bobKeyBytes));

      // Alice encrypts
      final plaintext = utf8.encode('Secret message from Alice');
      final secretBox =
          await aes.encrypt(plaintext, secretKey: aliceSessionKey);

      // Pack as CryptoService does: nonce || ciphertext || mac
      final packed = Uint8List(secretBox.nonce.length +
          secretBox.cipherText.length +
          secretBox.mac.bytes.length);
      var offset = 0;
      packed.setRange(
          offset, offset + secretBox.nonce.length, secretBox.nonce);
      offset += secretBox.nonce.length;
      packed.setRange(offset, offset + secretBox.cipherText.length,
          secretBox.cipherText);
      offset += secretBox.cipherText.length;
      packed.setRange(
          offset, offset + secretBox.mac.bytes.length, secretBox.mac.bytes);

      final ciphertextB64 = base64Encode(packed);
      debugPrint('Ciphertext: $ciphertextB64');

      // Bob decrypts
      final unpacked = base64Decode(ciphertextB64);
      final nonce = unpacked.sublist(0, 12);
      final cipherText = unpacked.sublist(12, unpacked.length - 16);
      final mac = Mac(unpacked.sublist(unpacked.length - 16));

      final recovered = SecretBox(cipherText, nonce: nonce, mac: mac);
      final decrypted =
          await aes.decrypt(recovered, secretKey: bobSessionKey);

      expect(utf8.decode(decrypted), equals('Secret message from Alice'));
      debugPrint('Decrypted: ${utf8.decode(decrypted)}');
    });
  });
}
