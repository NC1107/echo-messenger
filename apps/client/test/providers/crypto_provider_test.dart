import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/widgets/crypto_degraded_banner.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

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

  group('CryptoDegradedBanner', () {
    testWidgets('shows when crypto has error and is not initialized', (
      tester,
    ) async {
      await tester.pumpApp(
        const CryptoDegradedBanner(),
        overrides: [
          cryptoOverride(
            cryptoState: const CryptoState(
              isInitialized: false,
              error: 'Keyring unavailable',
            ),
          ),
        ],
      );

      expect(find.text('Keyring unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
    });

    testWidgets('hides when crypto is initialized', (tester) async {
      await tester.pumpApp(
        const CryptoDegradedBanner(),
        overrides: [
          cryptoOverride(cryptoState: const CryptoState(isInitialized: true)),
        ],
      );

      expect(find.text('Keyring unavailable'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('retry button triggers initAndUploadKeys', (tester) async {
      late FakeCryptoNotifier capturedNotifier;
      await tester.pumpApp(
        const CryptoDegradedBanner(),
        overrides: [
          cryptoProvider.overrideWith((ref) {
            capturedNotifier = FakeCryptoNotifier(
              ref,
              initial: const CryptoState(
                isInitialized: false,
                error: 'Keyring unavailable',
              ),
            );
            return capturedNotifier;
          }),
        ],
      );

      expect(capturedNotifier.initCallCount, 0);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(capturedNotifier.initCallCount, 1);
    });
  });
}
