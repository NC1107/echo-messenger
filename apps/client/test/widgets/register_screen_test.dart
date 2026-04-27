import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/register_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

GoRouter _buildRouter({required AuthState authState}) {
  return GoRouter(
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
}

Widget _buildApp({AuthState authState = const AuthState()}) {
  final router = _buildRouter(authState: authState);
  return ProviderScope(
    overrides: [authOverride(authState), serverUrlOverride()],
    child: MaterialApp.router(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    ),
  );
}

void main() {
  group('RegisterScreen', () {
    testWidgets('renders Create account header', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.text('Create account'), findsOneWidget);
    });

    testWidgets('renders username and password form fields', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    });

    testWidgets('renders confirm password field', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'Confirm password'),
        findsOneWidget,
      );
    });

    testWidgets('renders Register button', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Create account'),
        findsOneWidget,
      );
    });

    testWidgets('has link to login screen', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.text('Already have an account? Log in'), findsOneWidget);
    });

    testWidgets('tapping login link navigates to /login', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Already have an account? Log in'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });

    testWidgets('password fields are obscured', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      final obscuredFields = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((tf) => tf.obscureText)
          .toList();
      // Password + Confirm password should both be obscured
      expect(obscuredFields, hasLength(2));
    });

    testWidgets('shows loading spinner during registration', (tester) async {
      await tester.pumpWidget(_buildApp(authState: loadingAuthState));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('displays auth error message', (tester) async {
      await tester.pumpWidget(_buildApp(authState: errorAuthState));
      await tester.pumpAndSettle();

      expect(find.text('Invalid credentials'), findsOneWidget);
    });

    testWidgets('shows password hint text after focusing password field', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      // Hint is hidden on resting form — only shown after focus or submit attempt.
      expect(find.text('8-128 characters required'), findsNothing);

      await tester.tap(find.widgetWithText(TextField, 'Password'));
      await tester.pumpAndSettle();

      expect(find.text('8-128 characters required'), findsOneWidget);
    });

    testWidgets('validates empty form on submit', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      // Scroll down to make Register button visible if needed
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Username is required'), findsOneWidget);
    });

    testWidgets('validates short password on submit', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'testuser',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'short',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'short',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Must be at least 8 characters'), findsOneWidget);
    });

    testWidgets('validates password mismatch', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'testuser',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'different123',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('validates username with special characters', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'user@name!',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(
        find.text('Only letters, numbers, and underscores'),
        findsOneWidget,
      );
    });

    testWidgets('validates short username', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'ab',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Must be 3-32 characters'), findsOneWidget);
    });
  });
}
