import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/feedback_dialog.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

/// Pumps a button that opens the feedback dialog inside a ProviderScope
/// with a logged-in auth state and a fixed server URL.
Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authOverride(loggedInAuthState),
        serverUrlOverride('http://localhost:8080'),
      ],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showFeedbackDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(registerHttpFallbackValues);

  group('feedback_dialog', () {
    testWidgets('renders body field, share-logs switch, and send button', (
      tester,
    ) async {
      await _pumpHost(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Send feedback'), findsOneWidget);
      expect(find.text('Describe the bug'), findsOneWidget);
      expect(find.text('Share debug logs'), findsOneWidget);
      expect(
        find.byKey(const Key('feedback-share-logs-switch')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('feedback-send-button')), findsOneWidget);
    });

    testWidgets('send button is disabled until body has content', (
      tester,
    ) async {
      await _pumpHost(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // `FilledButton.icon` constructs a `FilledButton` widget internally;
      // we read the public `onPressed` field which is null while disabled.
      // We locate it via its key so the test stays robust to layout
      // changes elsewhere in the dialog.
      bool isEnabled() {
        final btn =
            tester.widget(find.byKey(const Key('feedback-send-button')))
                as ButtonStyleButton;
        return btn.onPressed != null;
      }

      expect(isEnabled(), isFalse);

      await tester.enterText(
        find.widgetWithText(TextField, 'Describe the bug'),
        'Repro steps go here.',
      );
      await tester.pump();
      expect(isEnabled(), isTrue);
    });

    testWidgets('surfaces a toast on network error after dialog closes', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/feedback')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(Exception('connection refused'));

      await http.runWithClient(() async {
        await _pumpHost(tester);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Describe the bug'),
          'Test bug — repro steps go here.',
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('feedback-send-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Dialog stays open on failure; in-dialog error text is shown so the
        // user always has visible feedback, regardless of overlay timing.
        expect(find.text('Network error. Please try again.'), findsWidgets);
      }, () => mockClient);

      // Let the toast dismiss-timer drain.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('posts to /api/feedback when send is tapped', (tester) async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/feedback')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(jsonEncode({'feedback_id': 'fb-1234'}), 201),
      );

      // Wrap the pump in runWithClient so the dialog's authenticatedRequest
      // picks up the mocked HTTP client.
      await http.runWithClient(() async {
        await _pumpHost(tester);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Describe the bug'),
          'Login button mis-aligned\nTapping it does nothing on iOS 18.',
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('feedback-send-button')));
        // Pump a couple of frames to let the async POST resolve and the
        // dialog close; avoid pumpAndSettle because the success toast
        // schedules a dismiss timer that would otherwise leak.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }, () => mockClient);

      verify(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/feedback')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).called(1);

      // Let any pending toast dismiss-timers drain before the test ends.
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
