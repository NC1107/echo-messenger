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

/// Extract the key bundle JSON from a FakeSecureKeyStore after init().
///
/// Returns the JSON map that the server /api/keys/bundle/:userId would return.
Future<Map<String, dynamic>> extractBundleFromStore(
  FakeSecureKeyStore store,
) async {
  final identityPubB64 = await store.read('echo_identity_pub_key');
  final signingPubB64 = await store.read('echo_signing_pub_key');
  final signingPrivB64 = await store.read('echo_signing_key');
  final signedPrekeyPubB64 = await store.read('echo_signed_prekey_pub');

  // Reconstruct Ed25519 signing key pair to produce the prekey signature.
  final signingKeyPair = SimpleKeyPairData(
    base64Decode(signingPrivB64!),
    publicKey: SimplePublicKey(
      base64Decode(signingPubB64!),
      type: KeyPairType.ed25519,
    ),
    type: KeyPairType.ed25519,
  );

  final signedPrekeyPubBytes = base64Decode(signedPrekeyPubB64!);
  final signature = await Ed25519().sign(
    signedPrekeyPubBytes,
    keyPair: signingKeyPair,
  );

  return {
    'identity_key': identityPubB64,
    'signing_key': signingPubB64,
    'signed_prekey': signedPrekeyPubB64,
    'signed_prekey_signature': base64Encode(signature.bytes),
    'signed_prekey_id': 1,
  };
}

void main() {
  late FakeSecureKeyStore aliceStore;
  late FakeSecureKeyStore bobStore;
  late CryptoService alice;
  late CryptoService bob;
  late MockHttpClient mockClient;
  late Map<String, dynamic> aliceBundle;
  late Map<String, dynamic> bobBundle;

  setUpAll(() {
    registerHttpFallbackValues();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    aliceStore = FakeSecureKeyStore();
    bobStore = FakeSecureKeyStore();
    mockClient = MockHttpClient();

    // Stub close() so runWithClient doesn't crash.
    when(() => mockClient.close()).thenReturn(null);

    // Init Alice.
    SecureKeyStore.instance = aliceStore;
    alice = CryptoService(serverUrl: 'http://localhost:8080');
    alice.setToken('alice-token');
    await alice.init();

    // Init Bob.
    SecureKeyStore.instance = bobStore;
    bob = CryptoService(serverUrl: 'http://localhost:8080');
    bob.setToken('bob-token');
    await bob.init();

    // Extract bundles for HTTP stubbing.
    aliceBundle = await extractBundleFromStore(aliceStore);
    bobBundle = await extractBundleFromStore(bobStore);

    // Stub HTTP responses.
    when(
      () => mockClient.get(
        any(
          that: predicate<Uri>((u) => u.path.contains('/api/keys/bundle/bob')),
        ),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => http.Response(jsonEncode(bobBundle), 200));

    when(
      () => mockClient.get(
        any(
          that: predicate<Uri>(
            (u) => u.path.contains('/api/keys/bundle/alice'),
          ),
        ),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => http.Response(jsonEncode(aliceBundle), 200));

    when(
      () => mockClient.post(
        any(that: predicate<Uri>((u) => u.path.contains('/api/keys/upload'))),
        headers: any(named: 'headers'),
        body: any(named: 'body'),
        encoding: any(named: 'encoding'),
      ),
    ).thenAnswer((_) async => http.Response('{}', 201));

    when(
      () => mockClient.get(
        any(
          that: predicate<Uri>((u) => u.path.contains('/api/keys/otp-count')),
        ),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => http.Response('{"count": 10}', 200));
  });

  /// Run [body] with the mock HTTP client and the correct SecureKeyStore.
  Future<T> asAlice<T>(Future<T> Function() body) async {
    SecureKeyStore.instance = aliceStore;
    return http.runWithClient(body, () => mockClient);
  }

  Future<T> asBob<T>(Future<T> Function() body) async {
    SecureKeyStore.instance = bobStore;
    return http.runWithClient(body, () => mockClient);
  }

  group('CryptoService encrypt/decrypt roundtrip', () {
    test('Alice encrypts, Bob decrypts (initial X3DH message)', () async {
      final ciphertext = await asAlice(
        () => alice.encryptMessage('bob', 'Hello Bob!'),
      );
      expect(ciphertext, isNotEmpty);

      final plaintext = await asBob(
        () => bob.decryptMessage('alice', ciphertext),
      );
      expect(plaintext, 'Hello Bob!');
    });

    test('Bob replies, Alice decrypts (established session)', () async {
      // Alice -> Bob (establishes session)
      final ct1 = await asAlice(() => alice.encryptMessage('bob', 'Hello'));
      await asBob(() => bob.decryptMessage('alice', ct1));

      // Bob -> Alice (Bob's response is an initial message from Bob's perspective)
      final ct2 = await asBob(() => bob.encryptMessage('alice', 'Hi Alice!'));
      final plain2 = await asAlice(() => alice.decryptMessage('bob', ct2));
      expect(plain2, 'Hi Alice!');
    });

    test('multiple messages in one direction', () async {
      // Alice -> Bob: first message (X3DH)
      final ct1 = await asAlice(() => alice.encryptMessage('bob', 'msg 1'));
      final pt1 = await asBob(() => bob.decryptMessage('alice', ct1));
      expect(pt1, 'msg 1');

      // Alice -> Bob: second message (same ratchet)
      final ct2 = await asAlice(() => alice.encryptMessage('bob', 'msg 2'));
      final pt2 = await asBob(() => bob.decryptMessage('alice', ct2));
      expect(pt2, 'msg 2');

      // Alice -> Bob: third message
      final ct3 = await asAlice(() => alice.encryptMessage('bob', 'msg 3'));
      final pt3 = await asBob(() => bob.decryptMessage('alice', ct3));
      expect(pt3, 'msg 3');
    });

    test('ping-pong conversation', () async {
      // Alice -> Bob
      final ct1 = await asAlice(() => alice.encryptMessage('bob', 'A1'));
      expect(await asBob(() => bob.decryptMessage('alice', ct1)), 'A1');

      // Bob -> Alice
      final ct2 = await asBob(() => bob.encryptMessage('alice', 'B1'));
      expect(await asAlice(() => alice.decryptMessage('bob', ct2)), 'B1');

      // Alice -> Bob
      final ct3 = await asAlice(() => alice.encryptMessage('bob', 'A2'));
      expect(await asBob(() => bob.decryptMessage('alice', ct3)), 'A2');

      // Bob -> Alice
      final ct4 = await asBob(() => bob.encryptMessage('alice', 'B2'));
      expect(await asAlice(() => alice.decryptMessage('bob', ct4)), 'B2');
    });

    test('unicode content', () async {
      const text = 'Hello! Emoji: \u{1F600}\u{1F389} Chinese: \u{4F60}\u{597D}';
      final ct = await asAlice(() => alice.encryptMessage('bob', text));
      final pt = await asBob(() => bob.decryptMessage('alice', ct));
      expect(pt, text);
    });

    test('empty content', () async {
      final ct = await asAlice(() => alice.encryptMessage('bob', ''));
      final pt = await asBob(() => bob.decryptMessage('alice', ct));
      expect(pt, '');
    });

    test(
      'ciphertexts are different for same plaintext (random nonce)',
      () async {
        final ct1 = await asAlice(() => alice.encryptMessage('bob', 'same'));
        // Decrypt so ratchet advances.
        await asBob(() => bob.decryptMessage('alice', ct1));

        final ct2 = await asAlice(() => alice.encryptMessage('bob', 'same'));
        expect(ct1, isNot(equals(ct2)));
      },
    );

    test(
      'decryptMessage throws for unknown peer with normal message',
      () async {
        // Construct a fake "normal" (non-X3DH) ciphertext — just random bytes.
        final fakeWire = base64Encode(
          Uint8List.fromList(List.generate(100, (i) => i)),
        );
        expect(
          () => asBob(() => bob.decryptMessage('unknown-peer', fakeWire)),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('session persists across CryptoService re-init', () async {
      // Establish session: Alice -> Bob
      final ct1 = await asAlice(
        () => alice.encryptMessage('bob', 'before restart'),
      );
      await asBob(() => bob.decryptMessage('alice', ct1));

      // Bob -> Alice to establish both directions
      final ct2 = await asBob(
        () => bob.encryptMessage('alice', 'establishing'),
      );
      await asAlice(() => alice.decryptMessage('bob', ct2));

      // Re-init Bob (simulating app restart, same store)
      SecureKeyStore.instance = bobStore;
      final bob2 = CryptoService(serverUrl: 'http://localhost:8080');
      bob2.setToken('bob-token');
      await bob2.init();

      // Alice sends another message — Bob2 should decrypt with restored session
      final ct3 = await asAlice(
        () => alice.encryptMessage('bob', 'after restart'),
      );
      final pt3 = await asBob(() => bob2.decryptMessage('alice', ct3));
      expect(pt3, 'after restart');
    });
  });
}
