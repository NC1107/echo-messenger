import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/screens/forgot_password_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

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
  });
}
