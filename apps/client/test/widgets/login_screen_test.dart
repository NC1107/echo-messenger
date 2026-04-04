import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/login_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

class _FailingLoginAuthNotifier extends AuthNotifier {
  _FailingLoginAuthNotifier(super.ref) {
    state = const AuthState();
  }

  @override
  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    state = state.copyWith(
      isLoading: false,
      error: 'Invalid username or password',
    );
  }

  @override
  Future<void> register(String username, String password) async {}

  @override
  Future<bool> tryAutoLogin() async => false;
}

/// Builds a minimal [GoRouter] that renders [LoginScreen] on `/login` and
/// captures navigation to `/register` and `/home`.
GoRouter _buildRouter({required AuthState authState}) {
  return GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('REGISTER_SCREEN'))),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('HOME_SCREEN'))),
      ),
    ],
  );
}

void main() {
  group('LoginScreen', () {
    testWidgets('renders username and password fields', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Echo'), findsOneWidget);
      expect(find.text('Encrypted messaging'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    });

    testWidgets('renders Login button', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Login'), findsOneWidget);
    });

    testWidgets('renders "Create an account" link', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Create an account'), findsOneWidget);
    });

    testWidgets('displays error when auth state has error', (tester) async {
      final router = _buildRouter(authState: errorAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(errorAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Invalid credentials'), findsOneWidget);
    });

    testWidgets('login button shows spinner when loading', (tester) async {
      final router = _buildRouter(authState: loadingAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loadingAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      // When loading, the button text should be replaced with a spinner
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The button should be disabled (onPressed == null)
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('password field is obscured', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final passwordField = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((tf) => tf.obscureText)
          .toList();
      expect(passwordField, hasLength(1));
    });

    testWidgets('can type in username and password fields', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'alice',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'secret123',
      );
      await tester.pump();

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('secret123'), findsOneWidget);
    });

    testWidgets('tapping "Create an account" navigates to /register', (
      tester,
    ) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();

      expect(find.text('REGISTER_SCREEN'), findsOneWidget);
    });

    testWidgets('displays version string', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedOutAuthState), serverUrlOverride()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The version text should contain 'Echo v'
      expect(find.textContaining('Echo v'), findsOneWidget);
    });

    testWidgets('keeps username and clears password on failed login', (
      tester,
    ) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _FailingLoginAuthNotifier(ref)),
            serverUrlOverride(),
          ],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'alice',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'wrong-password',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Login'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final fields = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .toList();
      expect(fields.first.controller?.text, 'alice');
      expect(fields[1].controller?.text, '');
      expect(find.text('Invalid username or password'), findsOneWidget);
    });
  });
}
