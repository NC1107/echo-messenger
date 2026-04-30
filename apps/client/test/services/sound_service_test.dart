import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/sound_service.dart';

void main() {
  // SoundService is a process-wide singleton.  We can reset observable state
  // between tests via the public setters, but cannot reset _initialized.
  // Each group restores state in setUp/tearDown to keep tests independent.

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // After each test restore known defaults so test ordering doesn't matter.
  tearDown(() async {
    SoundService().enabled = true;
    await SoundService().setNotificationSound(NotificationSound.defaultSound);
    SharedPreferences.setMockInitialValues({});
  });

  // ---------------------------------------------------------------------------
  // NotificationSound enum -- pure Dart, no platform dependencies
  // ---------------------------------------------------------------------------

  group('NotificationSound', () {
    test('none has prefValue "none"', () {
      expect(NotificationSound.none.prefValue, 'none');
    });

    test('defaultSound has prefValue "defaultSound"', () {
      expect(NotificationSound.defaultSound.prefValue, 'defaultSound');
    });

    test('subtle has prefValue "subtle"', () {
      expect(NotificationSound.subtle.prefValue, 'subtle');
    });

    test('fromPrefValue returns correct enum for all known values', () {
      expect(NotificationSound.fromPrefValue('none'), NotificationSound.none);
      expect(
        NotificationSound.fromPrefValue('defaultSound'),
        NotificationSound.defaultSound,
      );
      expect(NotificationSound.fromPrefValue('subtle'), NotificationSound.subtle);
    });

    test('fromPrefValue returns defaultSound for unknown value', () {
      expect(
        NotificationSound.fromPrefValue('unknown_value'),
        NotificationSound.defaultSound,
      );
    });

    test('fromPrefValue returns defaultSound for null', () {
      expect(NotificationSound.fromPrefValue(null), NotificationSound.defaultSound);
    });

    test('none assetPath is null', () {
      expect(NotificationSound.none.assetPath, isNull);
    });

    test('defaultSound assetPath is non-null', () {
      expect(NotificationSound.defaultSound.assetPath, isNotNull);
    });

    test('subtle assetPath is non-null', () {
      expect(NotificationSound.subtle.assetPath, isNotNull);
    });

    test('none label is "None"', () {
      expect(NotificationSound.none.label, 'None');
    });

    test('defaultSound label is "Default"', () {
      expect(NotificationSound.defaultSound.label, 'Default');
    });

    test('subtle label is "Subtle"', () {
      expect(NotificationSound.subtle.label, 'Subtle');
    });

    test('values covers all three cases', () {
      expect(NotificationSound.values, hasLength(3));
    });
  });

  // ---------------------------------------------------------------------------
  // SoundService.setNotificationSound
  // ---------------------------------------------------------------------------

  group('SoundService.setNotificationSound', () {
    test('updates the in-memory notificationSound to subtle', () async {
      await SoundService().setNotificationSound(NotificationSound.subtle);
      expect(SoundService().notificationSound, NotificationSound.subtle);
    });

    test('updates the in-memory notificationSound to none', () async {
      await SoundService().setNotificationSound(NotificationSound.none);
      expect(SoundService().notificationSound, NotificationSound.none);
    });

    test('persists selection to SharedPreferences (subtle)', () async {
      await SoundService().setNotificationSound(NotificationSound.subtle);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notification_sound'), 'subtle');
    });

    test('persists selection to SharedPreferences (none)', () async {
      await SoundService().setNotificationSound(NotificationSound.none);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notification_sound'), 'none');
    });

    test('persists selection to SharedPreferences (defaultSound)', () async {
      await SoundService().setNotificationSound(NotificationSound.defaultSound);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notification_sound'), 'defaultSound');
    });
  });

  // ---------------------------------------------------------------------------
  // SoundService.enabled setter
  // ---------------------------------------------------------------------------

  group('SoundService.enabled setter', () {
    test('setting enabled=false turns off sound', () {
      SoundService().enabled = false;
      expect(SoundService().enabled, isFalse);
    });

    test('setting enabled=true turns sound back on', () {
      SoundService().enabled = false;
      SoundService().enabled = true;
      expect(SoundService().enabled, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // SoundService factory (singleton identity)
  // ---------------------------------------------------------------------------

  group('SoundService singleton', () {
    test('factory returns the same object on every call', () {
      final a = SoundService();
      final b = SoundService();
      expect(identical(a, b), isTrue);
    });
  });
}

