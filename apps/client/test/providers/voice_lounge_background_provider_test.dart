import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/voice_lounge_background_provider.dart';

Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('VoiceLoungeBackground (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default state has no custom background path', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(voiceLoungeBackgroundProvider);
      await _flushLoad();
      expect(
        container.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        isNull,
      );
    });

    test('loads persisted path from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        kVoiceLoungeBgPathKey: '/tmp/test-bg.png',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(voiceLoungeBackgroundProvider);
      await _flushLoad();
      expect(
        container.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        '/tmp/test-bg.png',
      );
    });

    test('setCustomBackgroundPath updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(voiceLoungeBackgroundProvider);
      await _flushLoad();

      await container
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath('/tmp/custom.jpg');
      expect(
        container.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        '/tmp/custom.jpg',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kVoiceLoungeBgPathKey), '/tmp/custom.jpg');
    });

    test('clear removes the persisted path and resets state', () async {
      SharedPreferences.setMockInitialValues({
        kVoiceLoungeBgPathKey: '/tmp/old.png',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(voiceLoungeBackgroundProvider);
      await _flushLoad();

      await container.read(voiceLoungeBackgroundProvider.notifier).clear();
      expect(
        container.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        isNull,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kVoiceLoungeBgPathKey), isNull);
    });

    test('set → reload → still set', () async {
      final c1 = ProviderContainer();
      addTearDown(c1.dispose);
      c1.read(voiceLoungeBackgroundProvider);
      await _flushLoad();
      await c1
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath('/tmp/persist.png');

      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      c2.read(voiceLoungeBackgroundProvider);
      await _flushLoad();
      expect(
        c2.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        '/tmp/persist.png',
      );
    });

    test('setting null clears the persisted path', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(voiceLoungeBackgroundProvider);
      await _flushLoad();
      await container
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath('/tmp/a.png');
      await container
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath(null);
      expect(
        container.read(voiceLoungeBackgroundProvider).customBackgroundPath,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kVoiceLoungeBgPathKey), isNull);
    });
  });

  group('customBackgroundFileExists', () {
    test('returns false for null path', () {
      expect(customBackgroundFileExists(null), isFalse);
    });

    test('returns false for empty string', () {
      expect(customBackgroundFileExists(''), isFalse);
    });

    test('returns false for non-existent path', () {
      expect(
        customBackgroundFileExists('/definitely/not/a/real/path.png'),
        isFalse,
      );
    });
  });
}
