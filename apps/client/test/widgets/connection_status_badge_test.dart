// Tests for [ConnectionStatusBadge]: the sidebar brand-mark connection
// indicator. Covers dot colour per state, tap-to-open popover on mobile,
// the replaced-state "Sign in here" action, and clipboard copy of the
// diagnostics block.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketNotifier, WebSocketState, websocketProvider;
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/connection_status_badge.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Tracking fake WebSocket notifier
// ---------------------------------------------------------------------------

class _TrackingWsNotifier extends WebSocketNotifier {
  _TrackingWsNotifier(this._initial);

  final WebSocketState _initial;
  int connectCalls = 0;
  int reconnectAfterReplacementCalls = 0;

  @override
  WebSocketState build() => _initial;

  @override
  void connect() => connectCalls++;

  @override
  void disconnect() {}

  @override
  void reconnectAfterReplacement() {
    reconnectAfterReplacementCalls++;
    state = state.copyWith(wasReplaced: false);
  }
}

Override _wsOverride(WebSocketState initial) {
  return websocketProvider.overrideWith(() => _TrackingWsNotifier(initial));
}

// ---------------------------------------------------------------------------
// Test scaffold
// ---------------------------------------------------------------------------

Future<void> _pumpHarness(
  WidgetTester tester, {
  required List<Override> overrides,
  required Widget child,
  Size size = const Size(400, 800), // mobile by default
}) async {
  // Adjust the test surface to the requested logical size so the popover /
  // bottom sheet fits and `MediaQuery.sizeOf` returns the same dimensions.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        home: MediaQuery(
          // Tests run with reduced motion so the reconnecting pulse animation
          // doesn't block pumpAndSettle indefinitely.
          data: MediaQueryData(size: size, disableAnimations: true),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    ),
  );
}

// Finds the inner status dot (the 8 px circle painted by the badge). The
// dot is wrapped in an [IgnorePointer]; matching by border colour would
// require theme lookup, so we filter for a small circular [Container] with
// a [Border] (the popover's 10 px state dot inside the popover has no
// border, so this disambiguates).
Finder _statusDotFinder() {
  return find.byWidgetPredicate((w) {
    if (w is! Container) return false;
    final deco = w.decoration;
    if (deco is! BoxDecoration) return false;
    return deco.shape == BoxShape.circle && deco.border != null;
  });
}

Color _dotColor(WidgetTester tester) {
  final container = tester.widget<Container>(_statusDotFinder().first);
  return (container.decoration as BoxDecoration).color!;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionStatusBadge — dot colour per state', () {
    testWidgets('connected → online green', (tester) async {
      await _pumpHarness(
        tester,
        overrides: [
          serverUrlOverride(),
          _wsOverride(const WebSocketState(isConnected: true)),
        ],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();
      expect(_dotColor(tester), EchoTheme.online);
    });

    testWidgets('mid-reconnect → warning amber', (tester) async {
      await _pumpHarness(
        tester,
        overrides: [
          serverUrlOverride(),
          _wsOverride(
            const WebSocketState(isConnected: false, reconnectAttempts: 3),
          ),
        ],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();
      expect(_dotColor(tester), EchoTheme.warning);
    });

    testWidgets('past reconnect cutoff → danger red', (tester) async {
      await _pumpHarness(
        tester,
        overrides: [
          serverUrlOverride(),
          _wsOverride(
            const WebSocketState(isConnected: false, reconnectAttempts: 10),
          ),
        ],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();
      expect(_dotColor(tester), EchoTheme.danger);
    });

    testWidgets('session replaced → danger red', (tester) async {
      await _pumpHarness(
        tester,
        overrides: [
          serverUrlOverride(),
          _wsOverride(
            const WebSocketState(isConnected: false, wasReplaced: true),
          ),
        ],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();
      expect(_dotColor(tester), EchoTheme.danger);
    });
  });

  group('ConnectionStatusBadge — popover behaviour', () {
    testWidgets('tap on mobile opens the status popover', (tester) async {
      await _pumpHarness(
        tester,
        overrides: [
          serverUrlOverride(),
          _wsOverride(const WebSocketState(isConnected: true)),
        ],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();

      // Title is not visible before the popover opens.
      expect(find.text('Connected'), findsNothing);

      await tester.tap(find.byType(ConnectionStatusBadge));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Messages are delivered in real time.'), findsOneWidget);
    });

    testWidgets('replaced state — Sign in here calls '
        'reconnectAfterReplacement', (tester) async {
      late _TrackingWsNotifier capturedNotifier;
      final override = websocketProvider.overrideWith(() {
        capturedNotifier = _TrackingWsNotifier(
          const WebSocketState(isConnected: false, wasReplaced: true),
        );
        return capturedNotifier;
      });

      await _pumpHarness(
        tester,
        overrides: [serverUrlOverride(), override],
        child: const ConnectionStatusBadge(
          child: SizedBox(width: 22, height: 22),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(ConnectionStatusBadge));
      await tester.pumpAndSettle();

      expect(find.text('Signed in elsewhere'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in here'));
      await tester.pumpAndSettle();

      expect(capturedNotifier.reconnectAfterReplacementCalls, 1);
      expect(capturedNotifier.connectCalls, 0);
    });

    testWidgets(
      'expanding diagnostics + Copy writes the server URL to the clipboard',
      (tester) async {
        const testServerUrl = 'https://test.echo-messenger.example';
        String? capturedText;
        // Intercept platform-channel Clipboard.setData via the binary
        // messenger so we can assert what the popover wrote.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                final args = call.arguments;
                if (args is Map) {
                  capturedText = args['text'] as String?;
                }
              }
              return null;
            });

        try {
          await _pumpHarness(
            tester,
            // Tall surface so the expanded diagnostics block + copy button
            // stay inside the visible bottom-sheet area.
            size: const Size(400, 900),
            overrides: [
              serverUrlOverride(testServerUrl),
              _wsOverride(
                const WebSocketState(isConnected: false, reconnectAttempts: 4),
              ),
            ],
            child: const ConnectionStatusBadge(
              child: SizedBox(width: 22, height: 22),
            ),
          );
          await tester.pump();

          await tester.tap(find.byType(ConnectionStatusBadge));
          await tester.pumpAndSettle();

          // Expand the diagnostics drawer.
          await tester.tap(find.text('Show diagnostics'));
          await tester.pumpAndSettle();

          expect(find.text('Hide diagnostics'), findsOneWidget);
          expect(find.text(testServerUrl), findsOneWidget);

          await tester.tap(find.text('Copy diagnostics'));
          // Let the clipboard call complete + the toast schedule its dismiss
          // timer; then advance past the toast duration so no timers leak
          // beyond the widget tree's disposal.
          await tester.pump();
          await tester.pump(const Duration(seconds: 4));

          expect(capturedText, isNotNull);
          expect(capturedText, contains(testServerUrl));
          expect(capturedText, contains('Echo connection diagnostics'));
          expect(capturedText, contains('State:       reconnecting'));
          expect(capturedText, contains('Reconnects:  4 / 10'));
          expect(capturedText, contains('Replaced:    no'));
        } finally {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        }
      },
    );
  });
}
