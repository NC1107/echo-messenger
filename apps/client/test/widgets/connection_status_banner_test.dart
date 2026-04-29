import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/websocket_provider.dart';
import 'package:echo_app/src/widgets/connection_status_banner.dart';

/// Test subclass of [WebSocketNotifier] that exposes a public state setter
/// and replaces [connect] with a no-op so the Retry button doesn't fire
/// real network traffic.  We pass a real [Ref] from the ProviderScope so
/// the inherited init (typing-cleanup Timer) is harmless under the
/// fake_async pump cadence the widget tests use.
class _TestWsNotifier extends WebSocketNotifier {
  _TestWsNotifier(super.ref);

  void setStateForTest(WebSocketState next) => state = next;

  @override
  Future<void> connect() async {
    // Swallow the Retry-button call -- the test does not need a real WS.
  }
}

ProviderScope _wrap(_TestWsNotifier Function(Ref) build) {
  return ProviderScope(
    overrides: [websocketProvider.overrideWith((ref) => build(ref))],
    child: const MaterialApp(home: Scaffold(body: ConnectionStatusBanner())),
  );
}

void main() {
  group('ConnectionStatusBanner (#499)', () {
    testWidgets('hidden when connected', (tester) async {
      await tester.pumpWidget(
        _wrap((ref) {
          final n = _TestWsNotifier(ref);
          n.setStateForTest(const WebSocketState(isConnected: true));
          return n;
        }),
      );

      // Banner collapses to SizedBox.shrink when connected.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Reconnecting'), findsNothing);
      expect(find.textContaining('Connection lost'), findsNothing);
      expect(find.textContaining('Connected'), findsNothing);
    });

    testWidgets('shows reconnecting state with attempt counter', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap((ref) {
          final n = _TestWsNotifier(ref);
          n.setStateForTest(
            const WebSocketState(isConnected: false, reconnectAttempts: 2),
          );
          return n;
        }),
      );

      expect(find.text('Reconnecting... (2)'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('shows connection-lost + retry after 10 attempts', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap((ref) {
          final n = _TestWsNotifier(ref);
          n.setStateForTest(
            const WebSocketState(isConnected: false, reconnectAttempts: 10),
          );
          return n;
        }),
      );

      expect(
        find.textContaining('Connection lost'),
        findsOneWidget,
        reason: 'red banner replaces the spinner once max attempts hit',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('shows session-replaced label + retry', (tester) async {
      await tester.pumpWidget(
        _wrap((ref) {
          final n = _TestWsNotifier(ref);
          n.setStateForTest(
            const WebSocketState(isConnected: false, wasReplaced: true),
          );
          return n;
        }),
      );

      expect(find.text('Signed in on another device'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('flashes Connected after reconnect, then auto-hides', (
      tester,
    ) async {
      late _TestWsNotifier notifier;
      await tester.pumpWidget(
        _wrap((ref) {
          notifier = _TestWsNotifier(ref);
          notifier.setStateForTest(
            const WebSocketState(isConnected: false, reconnectAttempts: 1),
          );
          return notifier;
        }),
      );
      // Initial reconnecting state visible.
      expect(find.text('Reconnecting... (1)'), findsOneWidget);

      // Simulate reconnect.
      notifier.setStateForTest(
        const WebSocketState(isConnected: true, reconnectAttempts: 0),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Connected'), findsOneWidget);

      // After the 1.5s timer + AnimatedSize close, the banner is gone.
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Connected'), findsNothing);
    });
  });
}
