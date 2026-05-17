import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/screens/forgot_password_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: '/forgot-password',
    routes: [
      GoRoute(
        path: '/forgot-password',
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('LOGIN_SCREEN'))),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('RESET_SCREEN'))),
      ),
    ],
  );
}

Widget _wrap(GoRouter router) {
  return ProviderScope(
    overrides: [serverUrlOverride(), accessibilityOverride()],
    child: MaterialApp.router(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    ),
  );
}

void main() {
  setUpAll(registerHttpFallbackValues);

  group('ForgotPasswordScreen', () {
    testWidgets('renders username field and button', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      expect(find.text('Forgot password?'), findsNothing); // header text
      expect(find.text('Password recovery'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
      expect(find.text('Request reset'), findsOneWidget);
      expect(find.text('Back to login'), findsOneWidget);
    });

    testWidgets('empty username shows validation error', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Request reset'));
      await tester.pump();

      expect(find.text('Username is required'), findsOneWidget);
    });

    testWidgets('back-to-login navigates to /login', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back to login'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });

    testWidgets('success state shows manual-reset info banner', (tester) async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('', 200));

      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'alice',
      );

      await http.runWithClient(() async {
        await tester.tap(find.text('Request reset'));
        await tester.pump(); // trigger setState(_isLoading = true)
        await tester.pump(const Duration(seconds: 16)); // past timeout
      }, () => mockClient);
      await tester.pumpAndSettle();

      // Info banner with admin contact is visible.
      expect(
        find.textContaining('Password reset is not yet automated'),
        findsOneWidget,
      );
      expect(find.textContaining('admin@echo-messenger.us'), findsOneWidget);
      expect(find.text('Request received'), findsOneWidget);

      // Form is gone.
      expect(find.text('Request reset'), findsNothing);

      // Navigation buttons are present.
      expect(find.text('Enter reset token'), findsOneWidget);
      expect(find.text('Back to login'), findsOneWidget);
    });

    testWidgets(
      'success state enter-reset-token navigates to /reset-password',
      (tester) async {
        final mockClient = MockHttpClient();
        when(
          () => mockClient.post(
            any(),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer((_) async => http.Response('', 200));

        await tester.pumpWidget(_wrap(_buildRouter()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'),
          'alice',
        );

        await http.runWithClient(() async {
          await tester.tap(find.text('Request reset'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 16));
        }, () => mockClient);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Enter reset token'));
        await tester.tap(find.text('Enter reset token'));
        await tester.pumpAndSettle();

        expect(find.text('RESET_SCREEN'), findsOneWidget);
      },
    );
  });
}
