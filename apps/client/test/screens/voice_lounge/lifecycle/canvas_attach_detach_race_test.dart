// Regression: `CanvasController.attach()` awaits an HTTP fetch and writes
// the result into `state` afterwards. If the user leaves the lounge while
// that fetch is in flight, `detach()` runs first, clears state, and then
// the fetch's awaited completion (success path, error path, or non-200
// path) used to overwrite the cleared state — re-populating strokes /
// flipping `isLoaded: true` on a logically-detached canvas.
//
// Repro: spin up `attach()` against an unreachable server so the fetch's
// HTTP call throws a SocketException (catch branch). Call `detach()`
// immediately while the future is still awaiting. After the future
// resolves, the canvas state must still equal `CanvasState()` — the
// stale `isLoaded: true` write must NOT land.

import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/providers/auth/auth_provider.dart';
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState(
    isLoggedIn: true,
    token: 'test-token',
    userId: 'user-1',
    username: 'tester',
  );
}

class _StubServerUrlNotifier extends ServerUrlNotifier {
  @override
  String build() => 'http://127.0.0.1:1';
}

void main() {
  test(
    'detach during in-flight attach does not pollute state with stale fetch',
    () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(() => _StubAuthNotifier()),
          // Point at a guaranteed-dead host so the GET throws quickly
          // (connection refused). The catch branch is what used to leak
          // `isLoaded: true` into the cleared state.
          serverUrlProvider.overrideWith(() => _StubServerUrlNotifier()),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(canvasProvider.notifier);
      // Kick off attach without awaiting — the HTTP call is still in flight.
      final attachFuture = notifier.attach('conv-1', 'chan-1');
      // User leaves the lounge before the fetch resolves.
      notifier.detach();
      // Let the fetch error out and try to write state.
      await attachFuture;

      // Cleared state must remain — no isLoaded:true leak, no rehydrated
      // strokes from a stale response.
      final state = container.read(canvasProvider);
      expect(state.isLoaded, isFalse, reason: 'detach was supposed to clear');
      expect(state.strokes, isEmpty);
      expect(state.images, isEmpty);
      expect(state, equals(const CanvasState()));
    },
  );
}
