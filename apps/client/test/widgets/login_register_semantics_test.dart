import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/screens/login_screen.dart';
import 'package:echo_app/src/screens/register_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

GoRouter _loginRouter() => GoRouter(
  initialLocation: '/login',
  routes: [
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(
      path: '/register',
      builder: (_, _) =>
          const Scaffold(body: Center(child: Text('REGISTER_SCREEN'))),
    ),
  ],
);

GoRouter _registerRouter() => GoRouter(
  initialLocation: '/register',
  routes: [
    GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
    GoRoute(
      path: '/login',
      builder: (_, _) =>
          const Scaffold(body: Center(child: Text('LOGIN_SCREEN'))),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (_, _) =>
          const Scaffold(body: Center(child: Text('ONBOARDING_SCREEN'))),
    ),
  ],
);

Widget _wrapApp(GoRouter router) => ProviderScope(
  overrides: [authOverride(), serverUrlOverride(), accessibilityOverride()],
  child: MaterialApp.router(
    theme: EchoTheme.darkTheme,
    darkTheme: EchoTheme.darkTheme,
    themeMode: ThemeMode.dark,
    routerConfig: router,
  ),
);

void main() {
  group('LoginScreen semantics labels', () {
    testWidgets('login button has semantics label "login"', (tester) async {
      await tester.pumpWidget(_wrapApp(_loginRouter()));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('login'), findsOneWidget);
    });

    testWidgets(
      'create-account button has semantics label "Create an account"',
      (tester) async {
        await tester.pumpWidget(_wrapApp(_loginRouter()));
        await tester.pumpAndSettle();

        // Match the human-readable label that the e2e a11y suite expects
        // (`getByRole('button', { name: /create an account/i })`). The label
        // shows up on both the explicit Semantics wrapper and the inner Text
        // child (Flutter auto-derives), so accept either via findsWidgets.
        expect(find.bySemanticsLabel('Create an account'), findsWidgets);
      },
    );
  });

  group('RegisterScreen semantics labels', () {
    testWidgets('register button has semantics label "register"', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapApp(_registerRouter()));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('register'), findsOneWidget);
    });
  });
}
