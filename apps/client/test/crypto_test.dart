import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/signal_protocol.dart';
import 'package:echo_app/src/services/signal_session.dart';
import 'package:echo_app/src/services/signal_x3dh.dart';

void main() {
  group('Signal Protocol primitives', () {
    test('X25519 key generation works', () async {
      final x25519 = X25519();
      final keyPair = await x25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      expect(publicKey.bytes.length, equals(32));
    });

    test('HKDF key derivation produces 32 bytes', () async {
      final input = Uint8List(64)..fillRange(0, 64, 0xAB);
      final result = await x3dhKdf(input);
      expect(result.length, equals(32));
    });

    test('kdfRk produces 32-byte root key and chain key', () async {
      final rootKey = Uint8List(32)..fillRange(0, 32, 0x42);
      final dhOutput = Uint8List(32)..fillRange(0, 32, 0x13);
      final (newRoot, newChain) = await kdfRk(rootKey, dhOutput);
      expect(newRoot.length, equals(32));
      expect(newChain.length, equals(32));
      // Root and chain should be different
      expect(newRoot, isNot(equals(newChain)));
    });

    test('kdfCk produces distinct message key and next chain key', () async {
      final chainKey = Uint8List(32)..fillRange(0, 32, 0x55);
      final (nextChain, messageKey) = await kdfCk(chainKey);
      expect(nextChain.length, equals(32));
      expect(messageKey.length, equals(32));
      expect(nextChain, isNot(equals(messageKey)));
      // Chain key should have advanced
      expect(nextChain, isNot(equals(chainKey)));
    });

    test('encryptWithAd / decryptWithAd roundtrip', () async {
      final key = Uint8List(32)..fillRange(0, 32, 0x99);
      final plaintext = Uint8List.fromList(utf8.encode('Hello, Signal!'));
      final ad = Uint8List.fromList(utf8.encode('associated data'));

      final ciphertext = await encryptWithAd(key, plaintext, ad);
      expect(ciphertext.length, greaterThan(plaintext.length));

      final decrypted = await decryptWithAd(key, ciphertext, ad);
      expect(decrypted, equals(plaintext));
    });

    test('decryptWithAd rejects wrong AAD', () async {
      final key = Uint8List(32)..fillRange(0, 32, 0x99);
      final plaintext = Uint8List.fromList(utf8.encode('secret'));
      final ad = Uint8List.fromList(utf8.encode('correct ad'));
      final wrongAd = Uint8List.fromList(utf8.encode('wrong ad'));

      final ciphertext = await encryptWithAd(key, plaintext, ad);
      expect(() => decryptWithAd(key, ciphertext, wrongAd), throwsA(anything));
    });

    test('MessageHeader serialize/deserialize roundtrip', () {
      final header = MessageHeader(
        ratchetPublicKey: Uint8List(32)..fillRange(0, 32, 0xAB),
        prevChainLength: 42,
        messageNumber: 7,
      );

      final data = header.serialize();
      expect(data.length, equals(40));

      final restored = MessageHeader.deserialize(data);
      expect(restored.ratchetPublicKey, equals(header.ratchetPublicKey));
      expect(restored.prevChainLength, equals(42));
      expect(restored.messageNumber, equals(7));
    });
  });

  group('X3DH key agreement', () {
    test('Alice and Bob derive the same shared secret', () async {
      final x25519 = X25519();
      final aliceIdentity = await x25519.newKeyPair();
      final bobIdentity = await x25519.newKeyPair();
      final bobSignedPrekey = await x25519.newKeyPair();
      final bobOneTimePrekey = await x25519.newKeyPair();

      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();
      final bobOneTimePrekeyPub = await bobOneTimePrekey.extractPublicKey();
      final aliceIdentityPub = await aliceIdentity.extractPublicKey();

      // Alice initiates
      final initResult = await X3DH.initiate(
        aliceIdentity: aliceIdentity,
        bobIdentityKey: bobIdentityPub,
        bobSignedPrekey: bobSignedPrekeyPub,
        bobOneTimePrekey: bobOneTimePrekeyPub,
      );

      // Bob responds
      final bobSecret = await X3DH.respond(
        bobIdentity: bobIdentity,
        bobSignedPrekey: bobSignedPrekey,
        bobOneTimePrekey: bobOneTimePrekey,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: initResult.ephemeralPublic,
      );

      expect(initResult.sharedSecret, equals(bobSecret));
    });

    test('X3DH works without one-time prekey', () async {
      final x25519 = X25519();
      final aliceIdentity = await x25519.newKeyPair();
      final bobIdentity = await x25519.newKeyPair();
      final bobSignedPrekey = await x25519.newKeyPair();

      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();
      final aliceIdentityPub = await aliceIdentity.extractPublicKey();

      final initResult = await X3DH.initiate(
        aliceIdentity: aliceIdentity,
        bobIdentityKey: bobIdentityPub,
        bobSignedPrekey: bobSignedPrekeyPub,
      );

      final bobSecret = await X3DH.respond(
        bobIdentity: bobIdentity,
        bobSignedPrekey: bobSignedPrekey,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: initResult.ephemeralPublic,
      );

      expect(initResult.sharedSecret, equals(bobSecret));
    });

    test('Different initiators produce different secrets', () async {
      final x25519 = X25519();
      final alice = await x25519.newKeyPair();
      final eve = await x25519.newKeyPair();
      final bobIdentity = await x25519.newKeyPair();
      final bobSignedPrekey = await x25519.newKeyPair();

      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();

      final aliceResult = await X3DH.initiate(
        aliceIdentity: alice,
        bobIdentityKey: bobIdentityPub,
        bobSignedPrekey: bobSignedPrekeyPub,
      );
      final eveResult = await X3DH.initiate(
        aliceIdentity: eve,
        bobIdentityKey: bobIdentityPub,
        bobSignedPrekey: bobSignedPrekeyPub,
      );

      expect(aliceResult.sharedSecret, isNot(equals(eveResult.sharedSecret)));
    });
  });

  group('Double Ratchet (SignalSession)', () {
    /// Helper: create an Alice/Bob session pair from X3DH.
    Future<(SignalSession, SignalSession)> setupSessionPair() async {
      final x25519 = X25519();
      final aliceIdentity = await x25519.newKeyPair();
      final bobIdentity = await x25519.newKeyPair();
      final bobSignedPrekey = await x25519.newKeyPair();

      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();
      final aliceIdentityPub = await aliceIdentity.extractPublicKey();

      // X3DH
      final initResult = await X3DH.initiate(
        aliceIdentity: aliceIdentity,
        bobIdentityKey: bobIdentityPub,
        bobSignedPrekey: bobSignedPrekeyPub,
      );

      final bobSecret = await X3DH.respond(
        bobIdentity: bobIdentity,
        bobSignedPrekey: bobSignedPrekey,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: initResult.ephemeralPublic,
      );

      // Initialize ratchets
      final alice = await SignalSession.initAlice(
        initResult.sharedSecret,
        bobSignedPrekeyPub,
      );
      final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

      return (alice, bob);
    }

    test('Encrypt and decrypt a single message', () async {
      final (alice, bob) = await setupSessionPair();

      final plaintext = Uint8List.fromList(utf8.encode('Hello Bob!'));
      final wire = await alice.encrypt(plaintext);
      final decrypted = await bob.decrypt(wire);

      expect(utf8.decode(decrypted), equals('Hello Bob!'));
    });

    test('Multiple messages in one direction', () async {
      final (alice, bob) = await setupSessionPair();

      for (var i = 0; i < 10; i++) {
        final msg = 'Message $i';
        final wire = await alice.encrypt(Uint8List.fromList(utf8.encode(msg)));
        final pt = await bob.decrypt(wire);
        expect(utf8.decode(pt), equals(msg));
      }
    });

    test('Ping-pong conversation', () async {
      final (alice, bob) = await setupSessionPair();

      // Alice -> Bob
      var wire = await alice.encrypt(Uint8List.fromList(utf8.encode('Hi Bob')));
      var pt = await bob.decrypt(wire);
      expect(utf8.decode(pt), equals('Hi Bob'));

      // Bob -> Alice
      wire = await bob.encrypt(Uint8List.fromList(utf8.encode('Hi Alice')));
      pt = await alice.decrypt(wire);
      expect(utf8.decode(pt), equals('Hi Alice'));

      // Alice -> Bob again
      wire = await alice.encrypt(
        Uint8List.fromList(utf8.encode('How are you?')),
      );
      pt = await bob.decrypt(wire);
      expect(utf8.decode(pt), equals('How are you?'));

      // Bob -> Alice again
      wire = await bob.encrypt(Uint8List.fromList(utf8.encode('Good, you?')));
      pt = await alice.decrypt(wire);
      expect(utf8.decode(pt), equals('Good, you?'));
    });

    test('Out-of-order message delivery', () async {
      final (alice, bob) = await setupSessionPair();

      // Alice sends 3 messages
      final wire0 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 0')),
      );
      final wire1 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 1')),
      );
      final wire2 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 2')),
      );

      // Bob receives them out of order: 2, 0, 1
      expect(utf8.decode(await bob.decrypt(wire2)), equals('msg 2'));
      expect(utf8.decode(await bob.decrypt(wire0)), equals('msg 0'));
      expect(utf8.decode(await bob.decrypt(wire1)), equals('msg 1'));
    });

    test('Empty plaintext', () async {
      final (alice, bob) = await setupSessionPair();

      final wire = await alice.encrypt(Uint8List(0));
      final pt = await bob.decrypt(wire);
      expect(pt, isEmpty);
    });

    test('Large message (64KB)', () async {
      final (alice, bob) = await setupSessionPair();

      final bigMsg = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0xCD);
      final wire = await alice.encrypt(bigMsg);
      final pt = await bob.decrypt(wire);
      expect(pt, equals(bigMsg));
    });

    test('Wrong session cannot decrypt', () async {
      final (alice, _) = await setupSessionPair();
      final (_, eve) = await setupSessionPair();

      final wire = await alice.encrypt(
        Uint8List.fromList(utf8.encode('secret')),
      );
      expect(() => eve.decrypt(wire), throwsA(anything));
    });

    test('Forward secrecy: consumed keys are not reusable', () async {
      final (alice, bob) = await setupSessionPair();

      final wire0 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 0')),
      );
      final wire1 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 1')),
      );

      // Decrypt in order
      await bob.decrypt(wire0);
      await bob.decrypt(wire1);

      // Replaying should fail
      expect(() => bob.decrypt(wire0), throwsA(anything));
    });

    test('Session serialize/deserialize roundtrip', () async {
      final (alice, bob) = await setupSessionPair();

      // Exchange a message
      final wire = await alice.encrypt(
        Uint8List.fromList(utf8.encode('before serialize')),
      );
      await bob.decrypt(wire);

      // Serialize and restore Alice
      final aliceJson = await alice.toJson();
      final alice2 = SignalSession.fromJson(aliceJson);

      // Continue the conversation from restored state
      final wire2 = await alice2.encrypt(
        Uint8List.fromList(utf8.encode('after serialize')),
      );
      final pt2 = await bob.decrypt(wire2);
      expect(utf8.decode(pt2), equals('after serialize'));
    });

    test('Session JSON is SharedPreferences-compatible', () async {
      final (alice, _) = await setupSessionPair();

      final json = await alice.toJson();
      final jsonStr = jsonEncode(json);

      // Verify it round-trips through JSON string encoding
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final restored = SignalSession.fromJson(decoded);

      // Verify restored session can still encrypt
      final wire = await restored.encrypt(
        Uint8List.fromList(utf8.encode('test')),
      );
      expect(wire.length, greaterThan(44)); // 4 + 40 header + ciphertext
    });

    test('Multiple roundtrips (20 exchanges)', () async {
      final (alice, bob) = await setupSessionPair();

      for (var i = 0; i < 20; i++) {
        final msgAB = 'Alice to Bob $i';
        var wire = await alice.encrypt(Uint8List.fromList(utf8.encode(msgAB)));
        var pt = await bob.decrypt(wire);
        expect(utf8.decode(pt), equals(msgAB));

        final msgBA = 'Bob to Alice $i';
        wire = await bob.encrypt(Uint8List.fromList(utf8.encode(msgBA)));
        pt = await alice.decrypt(wire);
        expect(utf8.decode(pt), equals(msgBA));
      }
    });
  });
}
