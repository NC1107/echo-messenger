import 'package:echo_app/src/providers/ui_style_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pump enough microtasks for the build()-fired _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UiStyle enum', () {
    test('has discord, slack, and imessage values', () {
      expect(
        UiStyle.values,
        containsAll([UiStyle.discord, UiStyle.slack, UiStyle.imessage]),
      );
    });

    test('has exactly 3 values', () {
      expect(UiStyle.values, hasLength(3));
    });
  });

  group('UiStyleNotifier', () {
    test('defaults to discord', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(uiStyleProvider), UiStyle.discord);
    });

    test('persists and restores discord', () async {
      SharedPreferences.setMockInitialValues({'ui_style_v1': 'discord'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(uiStyleProvider);
      await _flushLoad();
      expect(container.read(uiStyleProvider), UiStyle.discord);
    });

    test('persists and restores slack', () async {
      SharedPreferences.setMockInitialValues({'ui_style_v1': 'slack'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(uiStyleProvider);
      await _flushLoad();
      expect(container.read(uiStyleProvider), UiStyle.slack);
    });

    test('persists and restores imessage', () async {
      SharedPreferences.setMockInitialValues({'ui_style_v1': 'imessage'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(uiStyleProvider);
      await _flushLoad();
      expect(container.read(uiStyleProvider), UiStyle.imessage);
    });

    test('setStyle writes to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(uiStyleProvider.notifier).setStyle(UiStyle.slack);
      expect(container.read(uiStyleProvider), UiStyle.slack);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ui_style_v1'), 'slack');
    });

    test('setStyle imessage writes correct key', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(uiStyleProvider.notifier).setStyle(UiStyle.imessage);
      expect(container.read(uiStyleProvider), UiStyle.imessage);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ui_style_v1'), 'imessage');
    });

    test('unknown stored value falls back to discord', () async {
      SharedPreferences.setMockInitialValues({'ui_style_v1': 'unknown_legacy'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(uiStyleProvider);
      await _flushLoad();
      expect(container.read(uiStyleProvider), UiStyle.discord);
    });
  });
}
