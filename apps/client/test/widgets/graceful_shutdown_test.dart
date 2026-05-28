// Regression test: App must perform a clean shutdown (WebSocket close + Hive
// flush) when the OS requests termination (SIGTERM on Linux, WM_CLOSE on
// Windows) instead of crashing mid-frame.
//
// Repro: kill -TERM <pid>  →  next launch shows recovery toast / dirty state.
//
// Root cause: no lifecycle observer called disconnect() on
// AppLifecycleState.detached, so the WS socket was never closed cleanly and
// Hive writes were not flushed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketNotifier, WebSocketState, websocketProvider;
import 'package:echo_app/src/widgets/shutdown_handler.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Tracking fake
// ---------------------------------------------------------------------------

class _TrackingWsNotifier extends WebSocketNotifier {
  _TrackingWsNotifier();

  @override
  WebSocketState build() => const WebSocketState(isConnected: true);

  int disconnectCalls = 0;

  @override
  void connect() {}

  @override
  void disconnect() => disconnectCalls++;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShutdownHandler', () {
    testWidgets('AppLifecycleState.detached triggers WebSocket disconnect', (
      tester,
    ) async {
      late _TrackingWsNotifier ws;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...standardOverrides(),
            websocketProvider.overrideWith(() {
              ws = _TrackingWsNotifier();
              return ws;
            }),
          ],
          child: const MaterialApp(
            home: ShutdownHandler(child: Scaffold(body: Text('app'))),
          ),
        ),
      );
      await tester.pump();

      // Before detached: no disconnect calls.
      expect(ws.disconnectCalls, 0);

      // Simulate OS-level termination signal (SIGTERM → detached lifecycle).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();

      // ShutdownHandler must have called disconnect() exactly once.
      expect(ws.disconnectCalls, 1);

      // Drain the 500 ms Hive.close timeout so no pending timers remain
      // after the widget tree is disposed (#1182).
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('non-detached lifecycle states do not trigger disconnect', (
      tester,
    ) async {
      late _TrackingWsNotifier ws;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...standardOverrides(),
            websocketProvider.overrideWith(() {
              ws = _TrackingWsNotifier();
              return ws;
            }),
          ],
          child: const MaterialApp(
            home: ShutdownHandler(child: Scaffold(body: Text('app'))),
          ),
        ),
      );
      await tester.pump();

      for (final state in [
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }

      expect(ws.disconnectCalls, 0);
    });
  });
}
