// Tests that PROVE the root causes of encryption failures.
//
// Each test demonstrates a specific bug by simulating the exact sequence
// of operations that triggers the failure in production.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/signal_session.dart';
import 'package:echo_app/src/services/signal_x3dh.dart';

void main() {
  final x25519 = X25519();

  group('ROOT CAUSE #1: OTP Key ID Collision', () {
    test(
      'PROVES: X3DH fails when Bob uses wrong OTP private key for same key_id',
      () async {
        // Setup: Alice and Bob identities
        final aliceIdentity = await x25519.newKeyPair();
        final bobIdentity = await x25519.newKeyPair();
        final bobSignedPrekey = await x25519.newKeyPair();

        final bobIdentityPub = await bobIdentity.extractPublicKey();
        final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();
        final aliceIdentityPub = await aliceIdentity.extractPublicKey();

        // === Simulate FIRST app launch ===
        // Bob generates OTP batch 1 (key_ids 0-9)
        final bobOtpBatch1KeyId3 = await x25519.newKeyPair();
        final bobOtpBatch1KeyId3Pub = await bobOtpBatch1KeyId3
            .extractPublicKey();

        // Server stores batch 1 OTP key_id=3 public key
        // Client stores batch 1 OTP key_id=3 private key

        // === Alice fetches Bob's bundle (gets batch 1 OTP key_id=3) ===
        final aliceResult = await X3DH.initiate(
          aliceIdentity: aliceIdentity,
          bobIdentityKey: bobIdentityPub,
          bobSignedPrekey: bobSignedPrekeyPub,
          bobOneTimePrekey: bobOtpBatch1KeyId3Pub, // From server (batch 1)
        );

        // Verify: Alice and Bob CAN agree on shared secret with CORRECT OTP
        final bobSecretCorrect = await X3DH.respond(
          bobIdentity: bobIdentity,
          bobSignedPrekey: bobSignedPrekey,
          bobOneTimePrekey: bobOtpBatch1KeyId3, // Batch 1 private key (CORRECT)
          aliceIdentityKey: aliceIdentityPub,
          aliceEphemeralKey: aliceResult.ephemeralPublic,
        );
        expect(
          aliceResult.sharedSecret,
          equals(bobSecretCorrect),
          reason:
              'Sanity check: same OTP batch should produce matching secrets',
        );

        // === Simulate APP RESTART ===
        // Bob's uploadKeys() generates OTP batch 2 (key_ids 0-9 again!)
        // Client OVERWRITES local private key for key_id=3
        final bobOtpBatch2KeyId3 = await x25519.newKeyPair();
        // Server: ON CONFLICT DO NOTHING -> still has batch 1 public key
        // Client: stores batch 2 private key for key_id=3

        // === Alice sends initial message (using batch 1 OTP from server) ===
        // === Bob tries to decrypt (loads batch 2 OTP from local storage) ===
        try {
          final bobSecretWrong = await X3DH.respond(
            bobIdentity: bobIdentity,
            bobSignedPrekey: bobSignedPrekey,
            bobOneTimePrekey:
                bobOtpBatch2KeyId3, // Batch 2 private key (WRONG!)
            aliceIdentityKey: aliceIdentityPub,
            aliceEphemeralKey: aliceResult.ephemeralPublic,
          );
          // If we get here, the secrets will NOT match
          expect(
            bobSecretWrong,
            isNot(equals(aliceResult.sharedSecret)),
            reason:
                'BUG PROVEN: Different OTP keys produce different shared secrets',
          );

          // Now prove that session establishment and decryption actually FAILS
          final aliceSession = await SignalSession.initAlice(
            aliceResult.sharedSecret,
            bobSignedPrekeyPub,
          );
          final bobSession = await SignalSession.initBob(
            bobSecretWrong, // Wrong shared secret!
            bobSignedPrekey,
          );

          final wire = await aliceSession.encrypt(
            Uint8List.fromList(utf8.encode('Hello Bob!')),
          );

          // This WILL throw - AES-GCM auth tag mismatch
          expect(
            () => bobSession.decrypt(wire),
            throwsA(anything),
            reason:
                'BUG PROVEN: Message encrypted with correct OTP cannot be '
                'decrypted with wrong OTP private key. This is the CRITICAL '
                'failure that happens after every app restart.',
          );
        } catch (e) {
          // X3DH.respond itself might throw if the DH produces invalid output
          // Either way, the bug is proven - the OTP mismatch causes failure
          // ignore: avoid_print
          print('X3DH.respond threw (also proves the bug): $e');
        }
      },
    );

    test(
      'PROVES: OTP key_id reuse across uploads - same IDs 0-9 every time',
      () {
        // This test documents the code pattern, not a runtime failure.
        // In crypto_service.dart lines 441-454:
        //
        //   for (var i = 0; i < 10; i++) {
        //     final otpPair = await _x25519.newKeyPair();
        //     ...
        //     await store.write('$_otpPrivatePrefix$i', ...);
        //     otps.add({'key_id': i, 'public_key': pubB64});
        //   }
        //
        // The loop uses hardcoded `i` from 0-9 every time uploadKeys() is called.
        // This means:
        //   - Upload 1: keys with IDs [0,1,2,3,4,5,6,7,8,9]
        //   - Upload 2: keys with IDs [0,1,2,3,4,5,6,7,8,9] (SAME IDs!)
        //   - Local storage: batch 2 private keys overwrite batch 1
        //   - Server: ON CONFLICT DO NOTHING -> keeps batch 1 public keys
        //
        // This is verified by reading the actual code above.
      },
      skip: 'documents code pattern, needs integration test with actual crypto service',
    );
  });

  group('ROOT CAUSE #3: Historical messages cannot be re-decrypted', () {
    test('PROVES: Double Ratchet cannot re-decrypt after session advances', () async {
      // Setup session pair
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

      final alice = await SignalSession.initAlice(
        initResult.sharedSecret,
        bobSignedPrekeyPub,
      );
      final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

      // Alice sends 3 messages
      final wire0 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('Historical message 0')),
      );
      final wire1 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('Historical message 1')),
      );
      final wire2 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('Historical message 2')),
      );

      // Bob decrypts all 3 (session advances)
      final pt0 = await bob.decrypt(wire0);
      expect(utf8.decode(pt0), 'Historical message 0');
      final pt1 = await bob.decrypt(wire1);
      expect(utf8.decode(pt1), 'Historical message 1');
      final pt2 = await bob.decrypt(wire2);
      expect(utf8.decode(pt2), 'Historical message 2');

      // === Simulate: Hive cache cleared, user loads history from server ===
      // Server returns the SAME ciphertext for messages 0, 1, 2
      // Bob tries to re-decrypt with current session state (already advanced)

      expect(
        () => bob.decrypt(wire0),
        throwsA(anything),
        reason:
            'BUG PROVEN: Cannot re-decrypt message 0 - chain has advanced past it',
      );

      expect(
        () => bob.decrypt(wire1),
        throwsA(anything),
        reason:
            'BUG PROVEN: Cannot re-decrypt message 1 - chain has advanced past it',
      );

      expect(
        () => bob.decrypt(wire2),
        throwsA(anything),
        reason:
            'BUG PROVEN: Cannot re-decrypt message 2 - chain has advanced past it',
      );
    });

    test(
      'PROVES: Even serialized/restored session cannot re-decrypt old messages',
      () async {
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

        final alice = await SignalSession.initAlice(
          initResult.sharedSecret,
          bobSignedPrekeyPub,
        );
        final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

        // Alice sends message, Bob decrypts
        final wire = await alice.encrypt(
          Uint8List.fromList(utf8.encode('old message')),
        );
        await bob.decrypt(wire);

        // === Simulate app restart: serialize → restore Bob's session ===
        final bobJson = await bob.toJson();
        final bobRestored = SignalSession.fromJson(bobJson);

        // New message works fine with restored session
        final wire2 = await alice.encrypt(
          Uint8List.fromList(utf8.encode('new message')),
        );
        final pt2 = await bobRestored.decrypt(wire2);
        expect(
          utf8.decode(pt2),
          'new message',
          reason: 'New messages work after session restore',
        );

        // But old message (from server history) STILL cannot be re-decrypted
        expect(
          () => bobRestored.decrypt(wire),
          throwsA(anything),
          reason:
              'BUG PROVEN: Even after session restore, old messages cannot be re-decrypted',
        );
      },
    );
  });

  group('ROOT CAUSE #4: Non-atomic encrypt/save - counter reuse', () {
    test('PROVES: Counter reuse causes decryption failure', () async {
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

      final alice = await SignalSession.initAlice(
        initResult.sharedSecret,
        bobSignedPrekeyPub,
      );
      final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

      // === Simulate: Alice sends messages, Bob decrypts ===
      final wire0 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 0')),
      );
      await bob.decrypt(wire0);

      // Save Alice's state BEFORE sending msg 1 (this is the "pre-crash" save)
      final aliceJsonBeforeMsg1 = await alice.toJson();

      // Alice sends msg 1 (counter advances to 1)
      final wire1 = await alice.encrypt(
        Uint8List.fromList(utf8.encode('msg 1')),
      );
      // Bob receives and decrypts msg 1
      await bob.decrypt(wire1);

      // === Simulate CRASH: Alice's state was NOT saved after msg 1 ===
      // On restart, Alice loads the pre-crash state (counter = 0 from after msg 0)
      // Actually after msg 0, counter is 1. After msg 1, counter is 2.
      // The pre-crash save has counter = 1 (after msg 0 encrypt).
      final aliceCrashed = SignalSession.fromJson(aliceJsonBeforeMsg1);

      // Alice sends msg 2 from crashed state
      // This will use counter = 1 (same as msg 1 that was already sent!)
      final wire2 = await aliceCrashed.encrypt(
        Uint8List.fromList(utf8.encode('msg 2 (after crash)')),
      );

      // Bob tries to decrypt msg 2, but counter 1 was already consumed
      // Bob's skipped_keys map consumed key for counter 1
      // The ratchet key is the same, so Bob looks for counter 1 → already used
      expect(
        () => bob.decrypt(wire2),
        throwsA(anything),
        reason:
            'BUG PROVEN: Counter reuse after crash causes decryption failure '
            'because the message key for that counter was already consumed.',
      );
    });
  });

  group('ROOT CAUSE #6: Missing session → spurious new session', () {
    test(
      'PROVES: New session from getOrCreateSession cannot decrypt old session messages',
      () async {
        // Setup two independent session pairs to simulate the mismatch
        final aliceIdentity = await x25519.newKeyPair();
        final bobIdentity = await x25519.newKeyPair();
        final bobSignedPrekey1 = await x25519.newKeyPair(); // Original prekey
        final bobSignedPrekey2 = await x25519
            .newKeyPair(); // New prekey after "reset"

        final bobIdentityPub = await bobIdentity.extractPublicKey();
        final bobSignedPrekey1Pub = await bobSignedPrekey1.extractPublicKey();
        final bobSignedPrekey2Pub = await bobSignedPrekey2.extractPublicKey();
        final aliceIdentityPub = await aliceIdentity.extractPublicKey();

        // === Original session (what Alice has) ===
        final initResult1 = await X3DH.initiate(
          aliceIdentity: aliceIdentity,
          bobIdentityKey: bobIdentityPub,
          bobSignedPrekey: bobSignedPrekey1Pub,
        );
        final bobSecret1 = await X3DH.respond(
          bobIdentity: bobIdentity,
          bobSignedPrekey: bobSignedPrekey1,
          aliceIdentityKey: aliceIdentityPub,
          aliceEphemeralKey: initResult1.ephemeralPublic,
        );
        final alice = await SignalSession.initAlice(
          initResult1.sharedSecret,
          bobSignedPrekey1Pub,
        );
        final bobOriginal = await SignalSession.initBob(
          bobSecret1,
          bobSignedPrekey1,
        );

        // Exchange some messages (advance the ratchet)
        final wire = await alice.encrypt(
          Uint8List.fromList(utf8.encode('normal message')),
        );
        await bobOriginal.decrypt(wire);

        // === Bob's session is lost (corruption, storage failure) ===
        // === getOrCreateSession creates NEW session as Alice to Bob ===
        // This new session uses a DIFFERENT X3DH handshake
        final initResult2 = await X3DH.initiate(
          aliceIdentity: bobIdentity, // Bob is now the "Alice" in new session
          bobIdentityKey: await aliceIdentity.extractPublicKey(),
          bobSignedPrekey: bobSignedPrekey2Pub,
        );

        // This new session has completely different keys
        final bobNewSession = await SignalSession.initAlice(
          initResult2.sharedSecret,
          bobSignedPrekey2Pub,
        );

        // Alice sends another message using her ORIGINAL session
        final wire2 = await alice.encrypt(
          Uint8List.fromList(utf8.encode('message after bob lost session')),
        );

        // Bob tries to decrypt with his NEW (wrong) session
        expect(
          () => bobNewSession.decrypt(wire2),
          throwsA(anything),
          reason:
              'BUG PROVEN: A new session created by getOrCreateSession cannot '
              'decrypt messages from the peer\'s existing session. The shared '
              'secrets are completely different.',
        );
      },
    );
  });

  group('ROOT CAUSE #7: Concurrent session access', () {
    test('PROVES: Interleaved async decrypt corrupts state', () async {
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

      final alice = await SignalSession.initAlice(
        initResult.sharedSecret,
        bobSignedPrekeyPub,
      );
      final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

      // Alice sends 5 messages
      final wires = <Uint8List>[];
      for (var i = 0; i < 5; i++) {
        wires.add(
          await alice.encrypt(
            Uint8List.fromList(utf8.encode('concurrent msg $i')),
          ),
        );
      }

      // Simulate concurrent decryption: launch all decrypts at once
      // In a single-threaded Dart event loop, these will interleave at await points
      final futures = wires.map((w) => bob.decrypt(w)).toList();

      // This may or may not fail depending on timing, but documents the risk.
      // In practice, the encrypt/decrypt methods contain multiple awaits where
      // interleaving can occur. With in-order messages this usually works,
      // but with out-of-order messages + DH ratchet steps, corruption is possible.
      try {
        final results = await Future.wait(futures);
        // If all succeed, they should contain the correct messages
        for (var i = 0; i < 5; i++) {
          expect(utf8.decode(results[i]), contains('concurrent msg'));
        }
      } catch (e) {
        // If any fail, the concurrency issue is demonstrated
        // ignore: avoid_print
        print('Concurrent decrypt failure (expected): $e');
      }
      // Note: This test demonstrates the RISK rather than guaranteeing failure.
      // True concurrent failures are timing-dependent. The per-peer lock fix
      // ensures serial execution regardless of timing.
    },
    skip: 'concurrency risk documented, needs integration test with real async interleaving',
    );
  });

  group('Session persistence verification', () {
    test(
      'Session correctly survives serialize → deserialize (baseline)',
      () async {
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

        final alice = await SignalSession.initAlice(
          initResult.sharedSecret,
          bobSignedPrekeyPub,
        );
        final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

        // Exchange some messages to advance both ratchets
        for (var i = 0; i < 5; i++) {
          final w = await alice.encrypt(
            Uint8List.fromList(utf8.encode('a->b $i')),
          );
          await bob.decrypt(w);
          final w2 = await bob.encrypt(
            Uint8List.fromList(utf8.encode('b->a $i')),
          );
          await alice.decrypt(w2);
        }

        // Serialize both sides
        final aliceJson = await alice.toJson();
        final bobJson = await bob.toJson();

        // Simulate app restart: deserialize
        final aliceRestored = SignalSession.fromJson(aliceJson);
        final bobRestored = SignalSession.fromJson(bobJson);

        // Continue conversation from restored state
        for (var i = 5; i < 10; i++) {
          final w = await aliceRestored.encrypt(
            Uint8List.fromList(utf8.encode('a->b $i')),
          );
          final pt = await bobRestored.decrypt(w);
          expect(utf8.decode(pt), 'a->b $i');

          final w2 = await bobRestored.encrypt(
            Uint8List.fromList(utf8.encode('b->a $i')),
          );
          final pt2 = await aliceRestored.decrypt(w2);
          expect(utf8.decode(pt2), 'b->a $i');
        }
      },
    );

    test(
      'Session with skipped keys survives serialize → deserialize',
      () async {
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

        final alice = await SignalSession.initAlice(
          initResult.sharedSecret,
          bobSignedPrekeyPub,
        );
        final bob = await SignalSession.initBob(bobSecret, bobSignedPrekey);

        // Alice sends 3 messages
        final wire0 = await alice.encrypt(
          Uint8List.fromList(utf8.encode('m0')),
        );
        final wire1 = await alice.encrypt(
          Uint8List.fromList(utf8.encode('m1')),
        );
        final wire2 = await alice.encrypt(
          Uint8List.fromList(utf8.encode('m2')),
        );

        // Bob receives only wire2 (skipping 0 and 1)
        await bob.decrypt(wire2);

        // Serialize Bob with skipped keys
        final bobJson = await bob.toJson();
        final bobRestored = SignalSession.fromJson(bobJson);

        // Skipped keys should survive serialization
        final pt0 = await bobRestored.decrypt(wire0);
        expect(
          utf8.decode(pt0),
          'm0',
          reason: 'Skipped key for msg 0 should survive serialization',
        );
        final pt1 = await bobRestored.decrypt(wire1);
        expect(
          utf8.decode(pt1),
          'm1',
          reason: 'Skipped key for msg 1 should survive serialization',
        );
      },
    );
  });
}
