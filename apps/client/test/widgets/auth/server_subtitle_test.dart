import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/auth/server_subtitle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the shared `ServerSubtitle` + the switch-server dialog it opens.
///
/// The dialog's HTTP pre-flight (`GET /api/server-info`) is exercised
/// indirectly — we drive the input field and confirm that submitting an
/// unreachable URL surfaces the inline error string without flipping the
/// active `serverUrlProvider`. We can't run a real HTTP server in a widget
/// test, so the "reachable" path is left to integration tests; what we lock
/// down here is that a typo can't log the user out (#1063 contract).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('ServerSubtitle', () {
    testWidgets('renders the active host with a chevron', (tester) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      expect(find.text('Server: echo-messenger.us'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('falls back to the raw URL when host is unparseable', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'not-a-url')),
      );
      expect(find.text('Server: not-a-url'), findsOneWidget);
    });

    testWidgets('exposes a semantics button labelled "switch server"', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'switch server',
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping opens the switch-server dialog', (tester) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'switch server',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Switch server'), findsOneWidget);
      expect(find.text('Custom URL'), findsOneWidget);
    });
  });

  group('Switch-server dialog', () {
    testWidgets('lists known servers when the provider has entries', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'echo_known_servers':
            '[{"url":"https://echo-messenger.us","last_seen":"2026-05-21T00:00:00.000Z"},'
            '{"url":"https://echo.example.com","last_seen":"2026-05-21T00:00:00.000Z"}]',
      });
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      // The provider only loads on demand — call it.
      final element = tester.element(find.byType(ServerSubtitle));
      final container = ProviderScope.containerOf(element);
      await container.read(serverUrlProvider.notifier).load();
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'switch server',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Known servers'), findsOneWidget);
      expect(find.text('echo-messenger.us'), findsOneWidget);
      expect(find.text('echo.example.com'), findsOneWidget);
    });

    testWidgets('hides the known-servers section when the list is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'switch server',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Known servers'), findsNothing);
      expect(find.text('Custom URL'), findsOneWidget);
    });

    testWidgets(
      'submitting an unreachable custom URL shows an inline error and does '
      'NOT flip the active server',
      (tester) async {
        await tester.pumpWidget(
          host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
        );
        final element = tester.element(find.byType(ServerSubtitle));
        final container = ProviderScope.containerOf(element);
        final activeBefore = container.read(serverUrlProvider);

        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'switch server',
          ),
        );
        await tester.pumpAndSettle();

        // `http://127.0.0.1:1` is reliably unreachable in a widget test;
        // the dialog's _preflight will timeout/connection-refuse.
        await tester.enterText(find.byType(TextField), 'http://127.0.0.1:1');
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        // Pre-flight has a 5s timeout — pump enough virtual time.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();

        // Either form is acceptable — depending on whether the test HTTP
        // layer returns "connection refused" (Could not reach) or surfaces a
        // 400 from the mock binding. The contract under test is that an
        // error is shown AND the active URL is unchanged.
        final errorShown =
            find.textContaining('Could not reach').evaluate().isNotEmpty ||
            find.textContaining('HTTP 400').evaluate().isNotEmpty ||
            find.textContaining('Server returned').evaluate().isNotEmpty;
        expect(
          errorShown,
          isTrue,
          reason: 'expected an inline pre-flight error',
        );
        expect(
          container.read(serverUrlProvider),
          activeBefore,
          reason: 'a typo must not log the user out',
        );
      },
    );

    testWidgets('Cancel closes the dialog without changing the active server', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ServerSubtitle(serverUrl: 'https://echo-messenger.us')),
      );
      final element = tester.element(find.byType(ServerSubtitle));
      final container = ProviderScope.containerOf(element);
      final activeBefore = container.read(serverUrlProvider);

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'switch server',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Switch server'), findsNothing);
      expect(container.read(serverUrlProvider), activeBefore);
    });
  });
}
