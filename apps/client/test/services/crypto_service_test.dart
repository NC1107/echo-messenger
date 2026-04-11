import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  late FakeSecureKeyStore fakeStore;

  setUp(() {
    fakeStore = FakeSecureKeyStore();
    SecureKeyStore.instance = fakeStore;
    SharedPreferences.setMockInitialValues({});
  });

  group('CryptoService construction', () {
    test('stores the server URL', () {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(crypto.serverUrl, 'http://localhost:8080');
    });

    test('isInitialized is false before init', () {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(crypto.isInitialized, isFalse);
    });

    test('keysAreFresh is false before init', () {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(crypto.keysAreFresh, isFalse);
    });

    test('keysWereRegenerated is false before init', () {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(crypto.keysWereRegenerated, isFalse);
    });
  });

  group('CryptoService.init', () {
    test('generates fresh identity keys on first run', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');

      await crypto.init();

      expect(crypto.isInitialized, isTrue);
      expect(crypto.keysAreFresh, isTrue);
      expect(crypto.keysWereRegenerated, isTrue);
      expect(crypto.deviceId, greaterThan(0));
    });

    test('generates a device ID on first run', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');

      await crypto.init();

      expect(crypto.deviceId, greaterThan(0));
      // Verify device ID was persisted
      final storedId = await fakeStore.read('echo_device_id');
      expect(storedId, isNotNull);
      expect(int.parse(storedId!), crypto.deviceId);
    });

    test('restores existing identity keys on subsequent runs', () async {
      // First run: generate keys
      final crypto1 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto1.setToken('test-token');
      await crypto1.init();

      final identityPub1 = await crypto1.getIdentityPublicKey();

      // Second run: should restore, not regenerate
      final crypto2 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto2.setToken('test-token');
      await crypto2.init();

      final identityPub2 = await crypto2.getIdentityPublicKey();

      expect(identityPub2, equals(identityPub1));
      expect(crypto2.keysWereRegenerated, isFalse);
    });

    test('restores device ID on subsequent runs', () async {
      final crypto1 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto1.setToken('test-token');
      await crypto1.init();
      final deviceId1 = crypto1.deviceId;

      final crypto2 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto2.setToken('test-token');
      await crypto2.init();

      expect(crypto2.deviceId, deviceId1);
    });

    test('persists identity key to secure storage', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      final storedPrivate = await fakeStore.read('echo_identity_key');
      final storedPublic = await fakeStore.read('echo_identity_pub_key');

      expect(storedPrivate, isNotNull);
      expect(storedPublic, isNotNull);
      // Should be valid base64
      expect(() => base64Decode(storedPrivate!), returnsNormally);
      expect(() => base64Decode(storedPublic!), returnsNormally);
    });

    test('generates signing key pair', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      final storedSigningPriv = await fakeStore.read('echo_signing_key');
      final storedSigningPub = await fakeStore.read('echo_signing_pub_key');
      expect(storedSigningPriv, isNotNull);
      expect(storedSigningPub, isNotNull);
    });

    test('generates signed prekey pair', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      final storedPrekey = await fakeStore.read('echo_signed_prekey');
      final storedPrekeyPub = await fakeStore.read('echo_signed_prekey_pub');
      expect(storedPrekey, isNotNull);
      expect(storedPrekeyPub, isNotNull);
    });

    test('getIdentityPublicKey returns valid key bytes', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      final pubKey = await crypto.getIdentityPublicKey();
      expect(pubKey, isNotNull);
      // X25519 public keys are 32 bytes
      expect(pubKey!.length, 32);
    });
  });

  group('CryptoService.setToken', () {
    test('accepts a token string', () {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      // Should not throw
      crypto.setToken('my-jwt-token');
    });
  });

  group('CryptoService.forceResetSession', () {
    test('removes session for a peer', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Force reset should not throw even if no session exists
      await crypto.forceResetSession('nonexistent-peer');
    });
  });

  group('CryptoService.clearKeys', () {
    test('clears all keys from storage', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Verify keys exist
      expect(await fakeStore.read('echo_identity_key'), isNotNull);

      await crypto.clearKeys();

      // After clearing, identity key should be gone
      expect(await fakeStore.read('echo_identity_key'), isNull);
    });
  });

  group('CryptoService.clearInMemoryState', () {
    test('resets initialization state', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();
      expect(crypto.isInitialized, isTrue);

      crypto.clearInMemoryState();
      expect(crypto.isInitialized, isFalse);
    });
  });

  group('CryptoService.hasCorruptedSession', () {
    test('returns false for unknown peers', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      expect(crypto.hasCorruptedSession('unknown-peer'), isFalse);
    });
  });

  group('CryptoService.invalidateSessionKey', () {
    test('removes a cached session for a peer', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Should not throw even if no session exists
      crypto.invalidateSessionKey('some-peer');
    });
  });

  group('SharedPreferences migration', () {
    test('migrates keys from SharedPreferences to SecureKeyStore', () async {
      // Pre-populate SharedPreferences with old-format keys
      SharedPreferences.setMockInitialValues({
        'echo_identity_key': base64Encode(List.generate(32, (i) => i)),
        'echo_identity_pub_key': base64Encode(List.generate(32, (i) => i + 50)),
      });

      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Keys should now be in secure storage
      expect(await fakeStore.read('echo_identity_key'), isNotNull);

      // They should be removed from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_identity_key'), isNull);
      expect(prefs.getString('echo_identity_pub_key'), isNull);
    });
  });
}
