import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/screens/reset_password_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: '/reset-password',
    routes: [
      GoRoute(
        path: '/reset-password',
        builder: (_, _) => const ResetPasswordScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('LOGIN_SCREEN'))),
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
  group('ResetPasswordScreen', () {
    testWidgets('renders all fields', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      // "Set new password" is both the subtitle and the submit button label.
      expect(find.text('Set new password'), findsNWidgets(2));
      expect(find.widgetWithText(TextFormField, 'Reset token'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'New password'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'Confirm new password'),
        findsOneWidget,
      );
      expect(find.text('Back to login'), findsOneWidget);
    });

    testWidgets('empty token shows validation error', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      // Tap the submit button without filling anything.
      await tester.tap(find.text('Set new password').last);
      await tester.pump();

      expect(find.text('Reset token is required'), findsOneWidget);
    });

    testWidgets('short password shows validation error', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Reset token'),
        'some-valid-token',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New password'),
        'short',
      );

      await tester.tap(find.text('Set new password').last);
      await tester.pump();

      expect(
        find.text('Password must be at least 8 characters'),
        findsOneWidget,
      );
    });

    testWidgets('mismatched passwords shows validation error', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Reset token'),
        'some-valid-token',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New password'),
        'password_one_123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm new password'),
        'password_two_456',
      );

      await tester.tap(find.text('Set new password').last);
      await tester.pump();

      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('back-to-login navigates to /login', (tester) async {
      await tester.pumpWidget(_wrap(_buildRouter()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back to login'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });
  });
}
