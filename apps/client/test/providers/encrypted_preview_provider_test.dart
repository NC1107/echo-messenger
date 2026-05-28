import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/encrypted_preview_provider.dart';

void main() {
  group('ShowEncryptedPreviews', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to true (previews visible)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // sync default before async load
      expect(container.read(showEncryptedPreviewsProvider), isTrue);
    });

    test('setValue(false) persists and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(showEncryptedPreviewsProvider.notifier)
          .setValue(false);

      expect(container.read(showEncryptedPreviewsProvider), isFalse);

      // Verify the pref was written.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kShowEncryptedPreviewsKey), isFalse);
    });

    test('setValue(true) after false restores default behavior', () async {
      SharedPreferences.setMockInitialValues({
        kShowEncryptedPreviewsKey: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(showEncryptedPreviewsProvider.notifier)
          .setValue(true);

      expect(container.read(showEncryptedPreviewsProvider), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kShowEncryptedPreviewsKey), isTrue);
    });

    test('loads persisted false on startup', () async {
      SharedPreferences.setMockInitialValues({
        kShowEncryptedPreviewsKey: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Trigger the async load.
      container.read(showEncryptedPreviewsProvider);
      // Allow the Future to resolve.
      await Future<void>.delayed(Duration.zero);

      expect(container.read(showEncryptedPreviewsProvider), isFalse);
    });

    test('kShowEncryptedPreviewsKey constant has correct value', () {
      expect(kShowEncryptedPreviewsKey, 'show_encrypted_previews');
    });
  });
}
