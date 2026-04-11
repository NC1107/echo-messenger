import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/crypto_provider.dart';

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
}
