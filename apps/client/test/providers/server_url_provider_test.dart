import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/server_url_provider.dart';

void main() {
  group('ServerUrlNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default URL is production', () {
      final notifier = ServerUrlNotifier();
      expect(notifier.state, defaultServerUrl);
      notifier.dispose();
    });

    test('load reads stored URL from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'echo_server_url': 'http://custom.example.com',
      });
      final notifier = ServerUrlNotifier();
      await notifier.load();
      expect(notifier.state, 'http://custom.example.com');
      notifier.dispose();
    });

    test('load keeps default when SharedPreferences is empty', () async {
      final notifier = ServerUrlNotifier();
      await notifier.load();
      expect(notifier.state, defaultServerUrl);
      notifier.dispose();
    });

    test('setUrl updates state and persists', () async {
      final notifier = ServerUrlNotifier();
      await notifier.setUrl('http://localhost:3000');
      expect(notifier.state, 'http://localhost:3000');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_server_url'), 'http://localhost:3000');
      notifier.dispose();
    });

    test('setUrl strips trailing slash', () async {
      final notifier = ServerUrlNotifier();
      await notifier.setUrl('http://example.com/');
      expect(notifier.state, 'http://example.com');
      notifier.dispose();
    });

    test(
      'resetToDefault restores default and removes persisted value',
      () async {
        final notifier = ServerUrlNotifier();
        await notifier.setUrl('http://custom.example.com');
        expect(notifier.state, 'http://custom.example.com');

        await notifier.resetToDefault();
        expect(notifier.state, defaultServerUrl);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('echo_server_url'), isNull);
        notifier.dispose();
      },
    );
  });

  group('wsUrlFromHttpUrl', () {
    test('converts https to wss', () {
      expect(
        wsUrlFromHttpUrl('https://echo-messenger.us'),
        'wss://echo-messenger.us',
      );
    });

    test('converts http to ws', () {
      expect(wsUrlFromHttpUrl('http://localhost:8080'), 'ws://localhost:8080');
    });

    test('falls back to wss for unknown scheme', () {
      expect(wsUrlFromHttpUrl('echo-messenger.us'), 'wss://echo-messenger.us');
    });
  });
}
