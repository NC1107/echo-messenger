/// Audit P0-1 acceptance tests for [SecureKeyStore] typed-exception
/// surfacing. Verifies that backend `PlatformException` failures (libsecret
/// locked / Keychain denied) become `StorageUnavailableException` so callers
/// can distinguish "no key" from "storage broken".
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  group('SecureKeyStore typed-exception surfacing (audit P0-1)', () {
    test('read returns null when key is absent', () async {
      final store = FakeSecureKeyStore();

      final result = await store.read('absent-key');

      expect(result, isNull);
    });

    test('read throws StorageUnavailableException when backend rejects '
        'with PlatformException', () async {
      final store = FakeSecureKeyStore();
      // Stage a backend failure — libsecret locked, Keychain prompt denied.
      store.throwOnRead['echo_signal_session_peer-A'] = PlatformException(
        code: 'storage-unavailable',
        message: 'libsecret backend unavailable',
      );

      await expectLater(
        store.read('echo_signal_session_peer-A'),
        throwsA(isA<StorageUnavailableException>()),
      );
    });

    test(
      'readGlobal also wraps PlatformException in StorageUnavailableException',
      () async {
        final store = FakeSecureKeyStore();
        store.throwOnRead['hive_message_cache_key'] = PlatformException(
          code: 'storage-unavailable',
          message: 'keychain prompt denied',
        );

        await expectLater(
          store.readGlobal('hive_message_cache_key'),
          throwsA(isA<StorageUnavailableException>()),
        );
      },
    );

    test(
      'StorageUnavailableException.toString includes operation name + cause',
      () {
        final cause = PlatformException(
          code: 'storage-unavailable',
          message: 'libsecret failure',
        );
        final exc = StorageUnavailableException('read(foo)', cause);

        final s = exc.toString();

        expect(s, contains('StorageUnavailableException'));
        expect(s, contains('read(foo)'));
        expect(s, contains('libsecret'));
      },
    );
  });
}
