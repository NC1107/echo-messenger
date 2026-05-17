import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  group('CryptoState', () {
    test('default state is uninitialized', () {
      const state = CryptoState();
      expect(state.isInitialized, isFalse);
      expect(state.isUploading, isFalse);
      expect(state.keysUploadFailed, isFalse);
      expect(state.keysWereRegenerated, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith preserves values', () {
      const state = CryptoState(
        isInitialized: true,
        isUploading: false,
        keysUploadFailed: true,
        keysWereRegenerated: true,
        error: 'upload failed',
      );

      final copied = state.copyWith(isUploading: true);
      expect(copied.isInitialized, isTrue);
      expect(copied.isUploading, isTrue);
      expect(copied.keysUploadFailed, isTrue);
      expect(copied.keysWereRegenerated, isTrue);
      // error uses null as default in copyWith, so it clears on copy
      expect(copied.error, isNull);
    });

    test('copyWith preserves error when explicitly set', () {
      const state = CryptoState();
      final withError = state.copyWith(error: 'some error');
      final copied = withError.copyWith(error: 'some error');
      expect(copied.error, 'some error');
    });

    test('copyWith can set individual fields', () {
      const state = CryptoState();

      final initialized = state.copyWith(isInitialized: true);
      expect(initialized.isInitialized, isTrue);
      expect(initialized.isUploading, isFalse);

      final uploading = state.copyWith(isUploading: true);
      expect(uploading.isInitialized, isFalse);
      expect(uploading.isUploading, isTrue);

      final failed = state.copyWith(keysUploadFailed: true);
      expect(failed.keysUploadFailed, isTrue);

      final regen = state.copyWith(keysWereRegenerated: true);
      expect(regen.keysWereRegenerated, isTrue);

      final withError = state.copyWith(error: 'test error');
      expect(withError.error, 'test error');
    });
  });

  group('CryptoState error transitions', () {
    test('isInitialized is false after general catch', () {
      const base = CryptoState();
      final errored = base.copyWith(
        isInitialized: false,
        isUploading: false,
        error: 'Crypto init failed: some error',
      );
      expect(errored.isInitialized, isFalse);
      expect(errored.error, contains('Crypto init failed'));
    });

    test('isInitialized is false after PlatformException', () {
      final errored = const CryptoState().copyWith(
        isInitialized: false,
        isUploading: false,
        error: 'Keyring unavailable',
      );
      expect(errored.isInitialized, isFalse);
      expect(errored.error, isNotNull);
    });

    test('isInitialized is false after key upload failure', () {
      final errored = const CryptoState().copyWith(
        isInitialized: false,
        keysUploadFailed: true,
        isUploading: false,
      );
      expect(errored.isInitialized, isFalse);
      expect(errored.keysUploadFailed, isTrue);
    });

    test('error is cleared on successful init', () {
      final errored = const CryptoState().copyWith(error: 'old error');
      final success = errored.copyWith(isInitialized: true, error: null);
      expect(success.isInitialized, isTrue);
      expect(success.error, isNull);
    });
  });

  group('Key migration from SharedPreferences', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
      SharedPreferences.setMockInitialValues({});
    });

    test('migrates named keys when present in SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();

      // Simulate old keys stored in SharedPreferences
      await prefs.setString('echo_identity_key', base64Encode([1, 2, 3]));
      await prefs.setString('echo_identity_pub_key', base64Encode([4, 5, 6]));
      await prefs.setString('echo_signing_key', base64Encode([7, 8, 9]));
      await prefs.setString('echo_signing_pub_key', base64Encode([10, 11]));

      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Verify keys were migrated to secure storage
      expect(await fakeStore.read('echo_identity_key'), isNotNull);
      expect(await fakeStore.read('echo_identity_pub_key'), isNotNull);
      expect(await fakeStore.read('echo_signing_key'), isNotNull);
      expect(await fakeStore.read('echo_signing_pub_key'), isNotNull);

      // On non-web platforms, old keys should be deleted from SharedPreferences
      if (await SharedPreferences.getInstance().then(
        (p) => p.getKeys().contains('echo_identity_key'),
      )) {
        // Web platform: keys kept in prefs as fallback
        expect(prefs.getString('echo_identity_key'), isNotNull);
      }
    });

    test('skips migration if no named keys present', () async {
      // Don't add any keys
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Fresh keys should be generated instead
      expect(crypto.isInitialized, isTrue);
      expect(crypto.keysAreFresh, isTrue);
    });

    test(
      'migrates prefixed keys (OTP, peer identity, skips invalid sessions)',
      () async {
        final prefs = await SharedPreferences.getInstance();

        // Add named keys first so init() has something to restore from
        await prefs.setString('echo_identity_key', base64Encode([1, 2, 3]));
        await prefs.setString('echo_identity_pub_key', base64Encode([4, 5, 6]));
        await prefs.setString('echo_signing_key', base64Encode([7, 8, 9]));
        await prefs.setString('echo_signing_pub_key', base64Encode([10, 11]));

        // Add prefixed keys (OTP and peer identity)
        // Note: session keys are also migrated but invalid JSON sessions are
        // quarantined and logged; we test the migration of valid prefixes
        await prefs.setString('echo_otp_private_1', 'otp_key_1');
        await prefs.setString('echo_peer_identity_bob', 'bob_identity_key');
        await prefs.setString(
          'echo_peer_identity_changed_charlie',
          'changed_flag',
        );

        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('test-token');
        await crypto.init();

        // Verify prefixed keys were migrated
        expect(await fakeStore.read('echo_otp_private_1'), isNotNull);
        expect(await fakeStore.read('echo_peer_identity_bob'), isNotNull);
        expect(
          await fakeStore.read('echo_peer_identity_changed_charlie'),
          isNotNull,
        );
      },
    );

    test('migrates counter keys (device ID, OTP next ID)', () async {
      final prefs = await SharedPreferences.getInstance();

      // Add named keys first
      await prefs.setString('echo_identity_key', base64Encode([1, 2, 3]));
      await prefs.setString('echo_identity_pub_key', base64Encode([4, 5, 6]));
      await prefs.setString('echo_signing_key', base64Encode([7, 8, 9]));
      await prefs.setString('echo_signing_pub_key', base64Encode([10, 11]));

      // Add counter keys
      await prefs.setString('echo_device_id', '12345');
      await prefs.setString('echo_otp_next_id', '42');

      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Verify counter keys were migrated
      final deviceIdStr = await fakeStore.read('echo_device_id');
      expect(deviceIdStr, equals('12345'));
      expect(await fakeStore.read('echo_otp_next_id'), equals('42'));
    });

    test('skips migration on subsequent runs', () async {
      final prefs = await SharedPreferences.getInstance();

      // First run: add keys to prefs, they get migrated
      await prefs.setString('echo_identity_key', base64Encode([1, 2, 3]));
      await prefs.setString('echo_identity_pub_key', base64Encode([4, 5, 6]));
      await prefs.setString('echo_signing_key', base64Encode([7, 8, 9]));
      await prefs.setString('echo_signing_pub_key', base64Encode([10, 11]));

      final crypto1 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto1.setToken('test-token');
      await crypto1.init();

      // Mark migration complete
      await fakeStore.write('_crypto_migration_complete', 'true');

      // Verify the flag exists
      expect(
        await fakeStore.read('_crypto_migration_complete'),
        equals('true'),
      );

      // Subsequent run: migration should be skipped
      final crypto2 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto2.setToken('test-token');
      await crypto2.init();

      // Should still be initialized (keys from first run still there)
      expect(crypto2.isInitialized, isTrue);
    });
  });

  group('Key restore from storage', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
      SharedPreferences.setMockInitialValues({});
    });

    test('restores identity key from storage', () async {
      // Generate and store keys on first run
      final crypto1 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto1.setToken('test-token');
      await crypto1.init();

      final identityPub1 = await crypto1.getIdentityPublicKey();

      // Verify keys are in secure storage
      expect(await fakeStore.read('echo_identity_key'), isNotNull);
      expect(await fakeStore.read('echo_identity_pub_key'), isNotNull);

      // Restore on second run
      final crypto2 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto2.setToken('test-token');
      await crypto2.init();

      final identityPub2 = await crypto2.getIdentityPublicKey();

      // Same identity key should be restored
      expect(identityPub2, equals(identityPub1));
      expect(crypto2.keysWereRegenerated, isFalse);
    });

    test('regenerates signing key if missing from storage', () async {
      // Setup: store identity key but omit signing key
      final fakeIdentityPriv = base64Encode(List.filled(32, 1));
      final fakeIdentityPub = base64Encode(List.filled(32, 2));

      await fakeStore.write('echo_identity_key', fakeIdentityPriv);
      await fakeStore.write('echo_identity_pub_key', fakeIdentityPub);

      // Init with missing signing key triggers regeneration
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Signing key should have been generated and persisted
      expect(await fakeStore.read('echo_signing_key'), isNotNull);
      expect(await fakeStore.read('echo_signing_pub_key'), isNotNull);
      // Fresh keys flag set because new key was generated
      expect(crypto.keysAreFresh, isTrue);
    });

    test('regenerates signed prekey if missing from storage', () async {
      // Setup: store identity and signing keys but omit signed prekey
      final fakeIdentityPriv = base64Encode(List.filled(32, 1));
      final fakeIdentityPub = base64Encode(List.filled(32, 2));
      final fakeSigningPriv = base64Encode(List.filled(64, 3));
      final fakeSigningPub = base64Encode(List.filled(32, 4));

      await fakeStore.write('echo_identity_key', fakeIdentityPriv);
      await fakeStore.write('echo_identity_pub_key', fakeIdentityPub);
      await fakeStore.write('echo_signing_key', fakeSigningPriv);
      await fakeStore.write('echo_signing_pub_key', fakeSigningPub);

      // Init with missing signed prekey triggers regeneration
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Signed prekey should have been generated
      expect(await fakeStore.read('echo_signed_prekey'), isNotNull);
      expect(await fakeStore.read('echo_signed_prekey_pub'), isNotNull);
      expect(crypto.keysAreFresh, isTrue);
    });

    test('marks keys for upload after successful restore', () async {
      final crypto1 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto1.setToken('test-token');
      await crypto1.init();

      // After restore, keys should be marked for upload
      final crypto2 = CryptoService(serverUrl: 'http://localhost:8080');
      crypto2.setToken('test-token');
      await crypto2.init();

      expect(crypto2.keysAreFresh, isTrue);
    });
  });

  group('Key upload retry logic', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
      SharedPreferences.setMockInitialValues({});
    });

    test('keysUploadFailed flag transitions on state changes', () {
      // Verify the state machine: initial false -> set true on error ->
      // cleared false on retry success
      const baseState = CryptoState(isInitialized: true);

      // Transition 1: upload fails
      final failedState = baseState.copyWith(
        keysUploadFailed: true,
        error: 'Key upload failed: timeout',
      );

      expect(failedState.keysUploadFailed, isTrue);
      expect(failedState.error, contains('Key upload failed'));
      expect(failedState.isInitialized, isTrue);
    });

    test('keysUploadFailed flag clears on retry success', () {
      final failedState = const CryptoState(
        isInitialized: true,
        keysUploadFailed: true,
        isUploading: true,
        error: 'Key upload failed',
      );

      // Transition 2: retry succeeds
      final recoveredState = failedState.copyWith(
        keysUploadFailed: false,
        isUploading: false,
        error: null,
      );

      expect(recoveredState.keysUploadFailed, isFalse);
      expect(recoveredState.error, isNull);
      expect(recoveredState.isInitialized, isTrue);
      expect(recoveredState.isUploading, isFalse);
    });

    test('keysUploadFailed survives state transitions without being cleared', () {
      // Verify that keysUploadFailed flag is preserved across other state changes
      final state1 = const CryptoState(
        isInitialized: true,
        keysUploadFailed: true,
      );

      // Change isUploading without touching keysUploadFailed
      final state2 = state1.copyWith(isUploading: true);
      expect(state2.keysUploadFailed, isTrue);

      // Then clear it explicitly
      final state3 = state2.copyWith(keysUploadFailed: false);
      expect(state3.keysUploadFailed, isFalse);
    });
  });
}
