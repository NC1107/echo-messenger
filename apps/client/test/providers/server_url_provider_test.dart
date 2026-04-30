import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_providers.dart';

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

  group('Server switching (PR 2)', () {
    /// Spin up a real ProviderContainer with auth + websocket overrides so
    /// the production [ServerUrlNotifier] runs end-to-end (load + switchTo +
    /// addKnownServer + forget). Auth's `logout(serverUrl: ...)` would
    /// otherwise hit the real network -- the override below records the
    /// call argument and just clears state.
    ProviderContainer makeContainer() {
      return ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            (ref) => _RecordingAuthNotifier(
              ref,
              initial: const AuthState(
                isLoggedIn: true,
                userId: 'u1',
                username: 'alice',
                token: 'access',
              ),
            ),
          ),
          webSocketOverride(),
        ],
      );
    }

    test('switchTo logs out then changes URL', () async {
      SharedPreferences.setMockInitialValues({
        'echo_server_url': 'https://server-a.example.com',
      });
      final container = makeContainer();
      addTearDown(container.dispose);

      final urlNotifier = container.read(serverUrlProvider.notifier);
      await urlNotifier.load();
      expect(container.read(serverUrlProvider), 'https://server-a.example.com');

      final auth =
          container.read(authProvider.notifier) as _RecordingAuthNotifier;

      await urlNotifier.switchTo('https://server-b.example.com');

      // (1) logout was called against the OLD origin BEFORE the URL flip.
      expect(auth.logoutCalls, hasLength(1));
      expect(auth.logoutCalls.first.serverUrl, 'https://server-a.example.com');
      expect(auth.logoutCalls.first.urlAtCall, 'https://server-a.example.com');

      // (2) URL flipped + persisted.
      expect(container.read(serverUrlProvider), 'https://server-b.example.com');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('echo_server_url'),
        'https://server-b.example.com',
      );

      // (3) Auth state cleared.
      expect(container.read(authProvider).isLoggedIn, isFalse);

      // (4) New URL is in known-servers list.
      final known = container.read(knownServersProvider);
      expect(known.map((s) => s.url), contains('https://server-b.example.com'));
    });

    test('known servers persists across restarts', () async {
      SharedPreferences.setMockInitialValues({
        'echo_server_url': 'https://server-a.example.com',
      });
      final c1 = makeContainer();
      addTearDown(c1.dispose);

      await c1.read(serverUrlProvider.notifier).load();
      await c1
          .read(serverUrlProvider.notifier)
          .switchTo('https://server-b.example.com');

      // Read fresh container (simulates app restart) -- must see both URLs.
      final c2 = makeContainer();
      addTearDown(c2.dispose);

      await c2.read(serverUrlProvider.notifier).load();
      final known = c2.read(knownServersProvider);
      final urls = known.map((s) => s.url).toSet();
      expect(urls, contains('https://server-a.example.com'));
      expect(urls, contains('https://server-b.example.com'));
    });

    test('forget server deletes known-servers entry', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(serverUrlProvider.notifier);
      await notifier.load();
      await notifier.addKnownServer(url: 'https://temp.example.com');
      expect(
        container.read(knownServersProvider).map((s) => s.url),
        contains('https://temp.example.com'),
      );

      await notifier.forget('https://temp.example.com');
      expect(
        container.read(knownServersProvider).map((s) => s.url),
        isNot(contains('https://temp.example.com')),
      );

      // Persisted across re-read.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('echo_known_servers') ?? '[]';
      expect(raw.contains('temp.example.com'), isFalse);
    });

    test('switchTo upserts last-seen on revisit', () async {
      SharedPreferences.setMockInitialValues({
        'echo_server_url': 'https://a.example.com',
      });
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(serverUrlProvider.notifier);
      await notifier.load();

      await notifier.switchTo('https://b.example.com');
      final firstSeen = container
          .read(knownServersProvider)
          .firstWhere((s) => s.url == 'https://b.example.com')
          .lastSeen;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await notifier.switchTo('https://a.example.com');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await notifier.switchTo('https://b.example.com');

      final secondSeen = container
          .read(knownServersProvider)
          .firstWhere((s) => s.url == 'https://b.example.com')
          .lastSeen;

      expect(
        secondSeen.isAfter(firstSeen),
        isTrue,
        reason: 'lastSeen must be bumped on revisit',
      );

      // No duplicate entries for the same URL.
      final bCount = container
          .read(knownServersProvider)
          .where((s) => s.url == 'https://b.example.com')
          .length;
      expect(bCount, 1);
    });
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

/// Captured arguments for an in-test logout invocation.
class _LogoutCall {
  final String? serverUrl;
  final String urlAtCall;
  _LogoutCall({required this.serverUrl, required this.urlAtCall});
}

/// AuthNotifier override that records `logout` invocations so the
/// switching tests can assert ordering ("logout BEFORE URL flip").
class _RecordingAuthNotifier extends AuthNotifier {
  final List<_LogoutCall> logoutCalls = [];

  _RecordingAuthNotifier(super.ref, {AuthState? initial}) {
    if (initial != null) state = initial;
  }

  @override
  Future<void> logout({String? serverUrl}) async {
    // Snapshot the active URL at call time so the test can assert that the
    // URL hadn't been flipped yet when logout fired.
    final urlAtCall = ref.read(serverUrlProvider);
    logoutCalls.add(_LogoutCall(serverUrl: serverUrl, urlAtCall: urlAtCall));
    state = const AuthState();
  }
}
