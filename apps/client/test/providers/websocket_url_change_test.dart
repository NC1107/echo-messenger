// PR-2 verification: changing the active server URL must tear down the
// current websocket and reconnect against the new origin.  Previously
// `connect()` read the URL via `ref.read`, so a switch silently kept the
// socket pointed at the OLD server.
//
// We can't bring up a real socket in unit tests, so we subclass
// [WebSocketNotifier] and count `connect`/`disconnect` calls.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart';

class _RecordingWsNotifier extends WebSocketNotifier {
  int connectCalls = 0;
  int disconnectCalls = 0;

  _RecordingWsNotifier(super.ref);

  @override
  void connect() {
    connectCalls++;
  }

  @override
  void disconnect() {
    disconnectCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WS reconnects when URL changes mid-session', () async {
    SharedPreferences.setMockInitialValues({
      'echo_server_url': 'https://a.example.com',
    });

    late _RecordingWsNotifier ws;
    final container = ProviderContainer(
      overrides: [
        // Authenticated session so the URL listener triggers a reconnect.
        authProvider.overrideWith(
          (ref) => _StubAuthNotifier(
            ref,
            const AuthState(
              isLoggedIn: true,
              userId: 'u1',
              username: 'alice',
              token: 'access',
            ),
          ),
        ),
        websocketProvider.overrideWith((ref) {
          ws = _RecordingWsNotifier(ref);
          return ws;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Force the websocket provider to be instantiated so its constructor's
    // ref.listen on serverUrlProvider is wired up before the URL flip.
    container.read(websocketProvider);
    final urlBefore = container.read(serverUrlProvider);
    final disconnectsBefore = ws.disconnectCalls;
    final connectsBefore = ws.connectCalls;

    // Flip the URL via setUrl (lower-level than switchTo, isolates the
    // listener behaviour from the logout flow).
    await container
        .read(serverUrlProvider.notifier)
        .setUrl('https://b.example.com');
    // Let pending microtasks settle so ref.listen callbacks fire.
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(serverUrlProvider),
      'https://b.example.com',
      reason: 'sanity: URL actually changed from $urlBefore',
    );
    expect(
      ws.disconnectCalls,
      greaterThan(disconnectsBefore),
      reason: 'old socket must be torn down on URL change',
    );
    expect(
      ws.connectCalls,
      greaterThan(connectsBefore),
      reason: 'new socket must be opened against the new origin',
    );
  });
}

/// Minimal AuthNotifier that just sets initial state. Defined here (instead
/// of using mock_providers') so the test owns the auth shape exactly.
class _StubAuthNotifier extends AuthNotifier {
  _StubAuthNotifier(super.ref, AuthState initial) {
    state = initial;
  }
}
