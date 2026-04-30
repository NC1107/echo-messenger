/// Regression test for #655 -- concurrent encrypt-to-different-peers must not
/// race on the X3DH initial-message state.
///
/// Before the fix, `_lastOtpKeyId` and `_lastX3dhResult` were instance fields
/// on [CryptoService]. `_withSessionLock` keys on `peerId|peerId:deviceId`, so
/// two concurrent calls to two different peers do not serialize and could
/// clobber each other's state -- the wire built for peer B could carry peer
/// A's OTP id, or even ship without an X3DH prefix at all if the other call
/// cleared the field first.
///
/// Fix: thread `(x3dhResult, otpKeyId)` as locals through the call stack.
/// This test fires `encryptForAllDevices` for two peers concurrently and
/// asserts each wire carries its own peer's OTP id, repeated 50 times to
/// flush out scheduler-dependent races.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';
import '../helpers/mock_http_client.dart';

/// Build a multi-device bundle response (`/api/keys/bundles/:userId`) for a
/// peer whose key material lives in [store], assigning it a deterministic
/// [otpKeyId]. The OTP public key is also generated here.
Future<Map<String, dynamic>> buildBundlesResponse(
  FakeSecureKeyStore store, {
  required int deviceId,
  required int otpKeyId,
}) async {
  final identityPubB64 = (await store.read('echo_identity_pub_key'))!;
  final signingPubB64 = (await store.read('echo_signing_pub_key'))!;
  final signingPrivB64 = (await store.read('echo_signing_key'))!;
  final signedPrekeyPubB64 = (await store.read('echo_signed_prekey_pub'))!;

  final signingKeyPair = SimpleKeyPairData(
    base64Decode(signingPrivB64),
    publicKey: SimplePublicKey(
      base64Decode(signingPubB64),
      type: KeyPairType.ed25519,
    ),
    type: KeyPairType.ed25519,
  );

  final signedPrekeyPubBytes = base64Decode(signedPrekeyPubB64);
  final signature = await Ed25519().sign(
    signedPrekeyPubBytes,
    keyPair: signingKeyPair,
  );

  // Generate a one-time prekey so the wire is V2 and carries an otp_id.
  final otpKeyPair = await X25519().newKeyPair();
  final otpPub = await otpKeyPair.extractPublicKey();

  return {
    'bundles': [
      {
        'device_id': deviceId,
        'identity_key': identityPubB64,
        'signing_key': signingPubB64,
        'signed_prekey': signedPrekeyPubB64,
        'signed_prekey_signature': base64Encode(signature.bytes),
        'signed_prekey_id': 1,
        'one_time_prekey': {
          'key_id': otpKeyId,
          'public_key': base64Encode(otpPub.bytes),
        },
      },
    ],
  };
}

/// Decode the V2 initial-message header out of a base64 wire and return its
/// otp_id (little-endian int32 at bytes 66..70). Throws if the wire is not V2.
int extractOtpId(String b64Wire) {
  final wire = base64Decode(b64Wire);
  expect(
    wire.length >= 70,
    isTrue,
    reason: 'wire too short to be a V2 initial header (got ${wire.length})',
  );
  expect(wire[0], 0xEC, reason: 'missing V2 magic byte 0');
  expect(
    wire[1],
    0x02,
    reason: 'expected V2 magic, got 0x${wire[1].toRadixString(16)}',
  );
  final bd = ByteData.sublistView(Uint8List.fromList(wire));
  return bd.getInt32(66, Endian.little);
}

void main() {
  setUpAll(() {
    registerHttpFallbackValues();
  });

  // 50 iterations to flush out scheduler-dependent races (#655).
  for (var i = 0; i < 50; i++) {
    test(
      'concurrent encryptForAllDevices preserves per-peer OTP id (run $i)',
      () async {
        SharedPreferences.setMockInitialValues({});

        // Two peer key stores -- "alice" (the sender), "peerA" and "peerB".
        final aliceStore = FakeSecureKeyStore();
        final peerAStore = FakeSecureKeyStore();
        final peerBStore = FakeSecureKeyStore();
        final mockClient = MockHttpClient();
        when(() => mockClient.close()).thenReturn(null);

        // Init alice (sender).
        SecureKeyStore.instance = aliceStore;
        final alice = CryptoService(serverUrl: 'http://localhost:8080');
        alice.setToken('alice-token');
        await alice.init();

        // Init the two peers so they have real X25519 keys we can serve.
        SecureKeyStore.instance = peerAStore;
        final peerA = CryptoService(serverUrl: 'http://localhost:8080');
        peerA.setToken('a-token');
        await peerA.init();

        SecureKeyStore.instance = peerBStore;
        final peerB = CryptoService(serverUrl: 'http://localhost:8080');
        peerB.setToken('b-token');
        await peerB.init();

        // Pick distinguishable OTP ids per peer.
        const otpIdA = 1111;
        const otpIdB = 2222;
        final bundlesA = await buildBundlesResponse(
          peerAStore,
          deviceId: 10,
          otpKeyId: otpIdA,
        );
        final bundlesB = await buildBundlesResponse(
          peerBStore,
          deviceId: 20,
          otpKeyId: otpIdB,
        );

        // Stub the multi-device bundles endpoint per peer.
        when(
          () => mockClient.get(
            any(
              that: predicate<Uri>(
                (u) => u.path.contains('/api/keys/bundles/peerA'),
              ),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response(jsonEncode(bundlesA), 200));

        when(
          () => mockClient.get(
            any(
              that: predicate<Uri>(
                (u) => u.path.contains('/api/keys/bundles/peerB'),
              ),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response(jsonEncode(bundlesB), 200));

        // Make sure alice is the active store while encrypting (her secure
        // storage has the identity / signed-prekey she needs).
        SecureKeyStore.instance = aliceStore;

        // Fire both encryptions concurrently -- the lock keys differ
        // (peerA:10 vs peerB:20) so they truly interleave.
        final results = await http.runWithClient(
          () => Future.wait([
            alice.encryptForAllDevices('peerA', 'msg-to-A'),
            alice.encryptForAllDevices('peerB', 'msg-to-B'),
          ]),
          () => mockClient,
        );

        final wiresA = results[0];
        final wiresB = results[1];

        expect(wiresA.containsKey('10'), isTrue, reason: 'A wire missing');
        expect(wiresB.containsKey('20'), isTrue, reason: 'B wire missing');

        // Core race assertion: each wire must carry its own peer's OTP id.
        expect(
          extractOtpId(wiresA['10']!),
          otpIdA,
          reason: 'peer A wire carried wrong OTP id (race #655)',
        );
        expect(
          extractOtpId(wiresB['20']!),
          otpIdB,
          reason: 'peer B wire carried wrong OTP id (race #655)',
        );
      },
    );
  }
}
