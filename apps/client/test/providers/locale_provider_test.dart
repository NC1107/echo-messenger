import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/locale_provider.dart';

/// Pump microtasks so the build()-fired _load() future settles.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('AppLocale (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default locale is English', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appLocaleProvider);
      await _flushLoad();
      expect(container.read(appLocaleProvider), const Locale('en'));
    });

    test('loads persisted locale from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'fr'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appLocaleProvider);
      await _flushLoad();
      expect(container.read(appLocaleProvider), const Locale('fr'));
    });

    test('loads all supported locale tags', () async {
      for (final entry in kSupportedLocales) {
        SharedPreferences.setMockInitialValues({kLocaleKey: entry.tag});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(appLocaleProvider);
        await _flushLoad();
        expect(
          container.read(appLocaleProvider),
          Locale(entry.tag),
          reason: '${entry.tag} should load correctly',
        );
      }
    });

    test('unknown locale tag falls back to English', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'xx'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appLocaleProvider);
      await _flushLoad();
      expect(container.read(appLocaleProvider), const Locale('en'));
    });

    test('setLocale updates state and persists to SharedPreferences', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appLocaleProvider);
      await _flushLoad();

      await container
          .read(appLocaleProvider.notifier)
          .setLocale(const Locale('ja'));
      expect(container.read(appLocaleProvider), const Locale('ja'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLocaleKey), 'ja');
    });

    test('select → persist → reload → still selected', () async {
      // Select Spanish in a fresh container.
      final container1 = ProviderContainer();
      addTearDown(container1.dispose);
      container1.read(appLocaleProvider);
      await _flushLoad();
      await container1
          .read(appLocaleProvider.notifier)
          .setLocale(const Locale('es'));

      // New container simulates an app restart loading from SharedPreferences.
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      container2.read(appLocaleProvider);
      await _flushLoad();
      expect(container2.read(appLocaleProvider), const Locale('es'));
    });

    test('localeProvider alias points at appLocaleProvider', () {
      expect(localeProvider, same(appLocaleProvider));
    });
  });

  group('kSupportedLocales', () {
    test('contains all expected starter locales', () {
      final tags = kSupportedLocales.map((e) => e.tag).toList();
      expect(tags, containsAll(['en', 'es', 'fr', 'de', 'pt', 'ja', 'zh']));
    });

    test('has 7 entries', () {
      expect(kSupportedLocales, hasLength(7));
    });

    test('first entry is English (default)', () {
      expect(kSupportedLocales.first.tag, 'en');
    });
  });

  group('supportedFlutterLocales', () {
    test('returns one Locale per kSupportedLocales entry', () {
      expect(supportedFlutterLocales, hasLength(kSupportedLocales.length));
    });

    test('contains Locale("en")', () {
      expect(supportedFlutterLocales, contains(const Locale('en')));
    });
  });

  group('localeDisplayName', () {
    test('returns display name for known tag', () {
      expect(localeDisplayName('en'), 'English');
      expect(localeDisplayName('fr'), 'Français');
      expect(localeDisplayName('ja'), '日本語');
    });

    test('returns raw tag for unknown locale', () {
      expect(localeDisplayName('xx'), 'xx');
    });
  });
}
