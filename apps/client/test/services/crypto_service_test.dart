import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/safety_number_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';
import '../helpers/mock_http_client.dart';

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
      // First-ever install: no prior keys existed, so this is NOT a
      // regeneration -- suppress the misleading "keys regenerated" warning.
      expect(crypto.keysWereRegenerated, isFalse);
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

  group('CryptoService identity-key change blocking (#580)', () {
    const peerId = 'peer-abc';
    const oldKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    const newKey = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=';

    test('hasPeerIdentityKeyChanged returns false when no flag set', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(await crypto.hasPeerIdentityKeyChanged(peerId), isFalse);
    });

    test('hasPeerIdentityKeyChanged returns true when flag set', () async {
      await fakeStore.write(
        'echo_peer_identity_changed_$peerId',
        DateTime.now().toIso8601String(),
      );
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(await crypto.hasPeerIdentityKeyChanged(peerId), isTrue);
    });

    test('acknowledgePeerIdentityKeyChange clears the flag', () async {
      await fakeStore.write(
        'echo_peer_identity_changed_$peerId',
        DateTime.now().toIso8601String(),
      );
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      expect(await crypto.hasPeerIdentityKeyChanged(peerId), isTrue);

      await crypto.acknowledgePeerIdentityKeyChange(peerId);
      expect(await crypto.hasPeerIdentityKeyChanged(peerId), isFalse);
    });

    test(
      'acceptIdentityKeyChange clears the flag and persists the new key',
      () async {
        await fakeStore.write('echo_peer_identity_$peerId', oldKey);
        await fakeStore.write(
          'echo_peer_identity_changed_$peerId',
          DateTime.now().toIso8601String(),
        );
        await fakeStore.write(
          'echo_signal_session_$peerId',
          '{"some":"session"}',
        );

        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        await crypto.acceptIdentityKeyChange(peerId, newIdentityKeyB64: newKey);

        expect(await crypto.hasPeerIdentityKeyChanged(peerId), isFalse);
        expect(await fakeStore.read('echo_peer_identity_$peerId'), newKey);
        // The old session is dropped so the next message X3DH's against the
        // freshly-trusted key.
        expect(await fakeStore.read('echo_signal_session_$peerId'), isNull);
      },
    );

    test(
      'acceptIdentityKeyChange without newIdentityKeyB64 keeps stored key',
      () async {
        await fakeStore.write('echo_peer_identity_$peerId', newKey);
        await fakeStore.write(
          'echo_peer_identity_changed_$peerId',
          DateTime.now().toIso8601String(),
        );

        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        await crypto.acceptIdentityKeyChange(peerId);

        expect(await crypto.hasPeerIdentityKeyChanged(peerId), isFalse);
        expect(await fakeStore.read('echo_peer_identity_$peerId'), newKey);
      },
    );

    test('IdentityKeyChangedException carries old and new keys', () {
      const exception = IdentityKeyChangedException(
        peerUserId: peerId,
        oldIdentityKeyB64: oldKey,
        newIdentityKeyB64: newKey,
      );
      expect(exception.peerUserId, peerId);
      expect(exception.oldIdentityKeyB64, oldKey);
      expect(exception.newIdentityKeyB64, newKey);
      expect(exception.toString(), contains(peerId));
    });
  });

  group('CryptoService.safetyNumberFor', () {
    test('returns null when no peer identity key is cached', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      expect(await crypto.safetyNumberFor('unknown-peer'), isNull);
    });

    test('returns a 60-digit fingerprint when both keys are present', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('test-token');
      await crypto.init();

      // Pretend we previously cached a peer identity key
      final fakePeerKey = base64Encode(List.generate(32, (i) => 200 - i));
      await fakeStore.write('echo_peer_identity_peer-1', fakePeerKey);

      final fp = await crypto.safetyNumberFor('peer-1');
      expect(fp, isNotNull);
      expect(fp!.length, 60);
      expect(RegExp(r'^\d{60}$').hasMatch(fp), isTrue);
    });

    test(
      'is deterministic regardless of arg order (commutative spec)',
      () async {
        // Mirrors SafetyNumberService.generate but exercised through
        // CryptoService so the helper signs off on the same property.
        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('test-token');
        await crypto.init();

        final myKeyBytes = await crypto.getIdentityPublicKey();
        expect(myKeyBytes, isNotNull);

        final peerKeyBytes = Uint8List.fromList(
          List.generate(32, (i) => i + 7),
        );
        await fakeStore.write(
          'echo_peer_identity_peer-2',
          base64Encode(peerKeyBytes),
        );

        final fromCryptoService = await crypto.safetyNumberFor('peer-2');
        // Direct call with swapped order should give the same result.
        final swapped = await SafetyNumberService.generate(
          peerKeyBytes,
          myKeyBytes!,
        );
        expect(fromCryptoService, swapped);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Per-device identity fingerprint + bundle heal (#664 / #662)
  // -------------------------------------------------------------------------
  group('CryptoService per-device identity (#664 #662)', () {
    setUpAll(() {
      registerHttpFallbackValues();
    });

    test(
      '409 with structured body surfaces IdentityKeyConflictException',
      () async {
        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('t');
        await crypto.init();

        final mockClient = MockHttpClient();
        when(() => mockClient.close()).thenReturn(null);
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path.contains('otp-count'))),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response('{"count": 10}', 200));
        when(
          () => mockClient.post(
            any(
              that: predicate<Uri>((u) => u.path.contains('/api/keys/upload')),
            ),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode({
              'code': 'identity_key_conflict',
              'device_id': 7,
              'expected_fingerprint': 'AAAA',
              'actual_fingerprint': 'BBBB',
            }),
            409,
          ),
        );

        Object? caught;
        await http.runWithClient(() async {
          try {
            await crypto.uploadKeys();
          } catch (e) {
            caught = e;
          }
        }, () => mockClient);

        expect(caught, isA<IdentityKeyConflictException>());
        final ex = caught as IdentityKeyConflictException;
        expect(ex.deviceId, 7);
        expect(ex.expectedFingerprint, 'AAAA');
        expect(ex.actualFingerprint, 'BBBB');
      },
    );

    test('legacy 409 (no JSON body) still throws typed exception', () async {
      final crypto = CryptoService(serverUrl: 'http://localhost:8080');
      crypto.setToken('t');
      await crypto.init();

      final mockClient = MockHttpClient();
      when(() => mockClient.close()).thenReturn(null);
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path.contains('otp-count'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('{"count": 10}', 200));
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path.contains('/api/keys/upload'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'error': 'Identity key changed'}), 409),
      );

      Object? caught;
      await http.runWithClient(() async {
        try {
          await crypto.uploadKeys();
        } catch (e) {
          caught = e;
        }
      }, () => mockClient);

      expect(caught, isA<IdentityKeyConflictException>());
      // Legacy bodies have no `device_id`; the exception falls back to the
      // local device id and leaves the fingerprints null.
      expect(
        (caught as IdentityKeyConflictException).expectedFingerprint,
        isNull,
      );
    });

    test(
      'bundle cache invalidated on first send when no session exists',
      () async {
        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('t');
        await crypto.init();

        // Pre-seed the bundle cache for a peer we have NO session with.
        crypto.debugSeedBundleCache('peer-stale', [
          {'device_id': 0, 'identity_key': 'AAAA'},
        ]);
        expect(crypto.debugBundleCacheContains('peer-stale'), isTrue);

        // Mock /api/keys/bundles/<peer>: returning empty list lets us assert
        // (a) the network was actually hit (cache was evicted instead of
        // returned-from-cache) and (b) encryptForAllDevices fell back through
        // gracefully.
        final mockClient = MockHttpClient();
        when(() => mockClient.close()).thenReturn(null);
        var bundlesGetCalls = 0;
        when(
          () => mockClient.get(
            any(
              that: predicate<Uri>(
                (u) => u.path.contains('/api/keys/bundles/peer-stale'),
              ),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async {
          bundlesGetCalls += 1;
          return http.Response(jsonEncode({'bundles': []}), 200);
        });
        // Stub the legacy single-bundle endpoint that the empty-bundle
        // fallback path routes through (encryptMessage -> getOrCreateSession).
        when(
          () => mockClient.get(
            any(
              that: predicate<Uri>(
                (u) => u.path.contains('/api/keys/bundle/peer-stale'),
              ),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response('{}', 404));

        await http.runWithClient(() async {
          try {
            await crypto.encryptForAllDevices('peer-stale', 'hi');
          } catch (_) {
            // We expect the empty-bundle fallback path to fail with no
            // bundle available; the test only cares about cache eviction +
            // network round-trip.
          }
        }, () => mockClient);

        expect(
          bundlesGetCalls,
          greaterThan(0),
          reason:
              'first-send heal must drop stale cached bundle and re-fetch '
              'from /api/keys/bundles/<peer>',
        );
      },
    );

    test(
      'resetThisDeviceKeys regenerates self-only and preserves peer sessions',
      () async {
        final fakeStore = FakeSecureKeyStore();
        SecureKeyStore.instance = fakeStore;
        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('t');
        await crypto.init();

        final priorIdentityB64 = await fakeStore.read('echo_identity_pub_key');

        // Seed peer sessions for A and B (raw JSON blobs). They should
        // survive the reset because they're keyed on peerUserId, not
        // myUserId.
        await fakeStore.write(
          'echo_signal_session_peer-a',
          '{"some":"sessionA"}',
        );
        await fakeStore.write(
          'echo_signal_session_peer-b:1',
          '{"some":"sessionB"}',
        );
        // Seed a self-session that SHOULD be cleared.
        await fakeStore.write(
          'echo_signal_session_me-uid:1',
          '{"some":"selfSess"}',
        );

        final mockClient = MockHttpClient();
        when(() => mockClient.close()).thenReturn(null);
        when(
          () => mockClient.post(
            any(
              that: predicate<Uri>(
                (u) => u.path.contains('/api/keys/reset_device'),
              ),
            ),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer((_) async => http.Response('', 204));
        when(
          () => mockClient.post(
            any(
              that: predicate<Uri>((u) => u.path.contains('/api/keys/upload')),
            ),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer((_) async => http.Response('{}', 201));
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path.contains('otp-count'))),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response('{"count": 10}', 200));

        await http.runWithClient(
          () => crypto.resetThisDeviceKeys('pw', myUserId: 'me-uid'),
          () => mockClient,
        );

        final newIdentityB64 = await fakeStore.read('echo_identity_pub_key');
        expect(
          newIdentityB64,
          isNot(equals(priorIdentityB64)),
          reason: 'identity key must be regenerated',
        );
        // Peer sessions intact.
        expect(await fakeStore.read('echo_signal_session_peer-a'), isNotNull);
        expect(await fakeStore.read('echo_signal_session_peer-b:1'), isNotNull);
        // Self-session cleared.
        expect(await fakeStore.read('echo_signal_session_me-uid:1'), isNull);
      },
    );

    test(
      'initial X3DH decrypt failure throws InitialDecryptFailedException',
      () async {
        final crypto = CryptoService(serverUrl: 'http://localhost:8080');
        crypto.setToken('t');
        await crypto.init();

        // Build a corrupt initial-V1 wire whose AES-GCM body is properly
        // shaped (header_len + header + nonce + ct + tag) but cannot
        // authenticate. The decryptInitial path runs X3DH, derives a session,
        // then session.decrypt throws -> heal path triggers.
        final headerLen = 40;
        final body = Uint8List(4 + headerLen + 12 + 32 + 16);
        // header_len LE
        final bd = ByteData.sublistView(body);
        bd.setInt32(0, headerLen, Endian.little);
        // Fill the rest with a deterministic pattern so AES-GCM fails auth.
        for (var i = 4; i < body.length; i++) {
          body[i] = (i * 37) & 0xff;
        }
        final corrupt = Uint8List(2 + 32 + 32 + body.length);
        corrupt[0] = 0xEC;
        corrupt[1] = 0x01;
        for (var i = 2; i < 66; i++) {
          // identity/ephemeral pubkeys (random bytes)
          corrupt[i] = (i * 11) & 0xff;
        }
        corrupt.setRange(66, corrupt.length, body);
        final corruptB64 = base64Encode(corrupt);

        final mockClient = MockHttpClient();
        when(() => mockClient.close()).thenReturn(null);

        var uploadCalled = false;
        when(
          () => mockClient.post(
            any(
              that: predicate<Uri>((u) => u.path.contains('/api/keys/upload')),
            ),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer((_) async {
          uploadCalled = true;
          return http.Response('{}', 201);
        });
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path.contains('otp-count'))),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async => http.Response('{"count": 10}', 200));

        Object? caught;
        await http.runWithClient(() async {
          try {
            await crypto.decryptMessage('peer-x', corruptB64);
          } catch (e) {
            caught = e;
          }
          // Give the fire-and-forget uploadKeys a tick to run.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }, () => mockClient);

        expect(caught, isA<InitialDecryptFailedException>());
        expect(
          uploadCalled,
          isTrue,
          reason: 'heal path must fire-and-forget uploadKeys()',
        );
      },
    );
  });
}
