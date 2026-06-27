import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/login_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

class _FailingLoginAuthNotifier extends AuthNotifier {
  _FailingLoginAuthNotifier();

  @override
  AuthState build() => const AuthState();

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

/// Auth notifier whose `login` / `logout` can be driven from a test so we can
/// reproduce the account-switch flow on a kept-alive login screen.
class _SwitchableAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState();

  @override
  Future<void> login(String username, String password) async {
    state = const AuthState(
      isLoggedIn: true,
      userId: 'user-a',
      username: 'echoqa_alice',
      token: 'tok',
    );
  }

  @override
  Future<void> register(String username, String password) async {}

  @override
  Future<bool> tryAutoLogin() async => false;

  @override
  Future<void> logout({String? serverUrl, bool forgetAccount = true}) async =>
      state = const AuthState();
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
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      expect(find.text('Echo'), findsOneWidget);
      expect(
        find.text('End-to-end encrypted. Zero telemetry.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    });

    testWidgets('renders Login button', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    });

    testWidgets('renders "Create an account" link', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      expect(find.text('Create an account'), findsOneWidget);
    });

    testWidgets('displays error when auth state has error', (tester) async {
      final router = _buildRouter(authState: errorAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authOverride(errorAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      expect(find.text('Invalid credentials'), findsOneWidget);
    });

    testWidgets('login button shows spinner when loading', (tester) async {
      final router = _buildRouter(authState: loadingAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authOverride(loadingAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
          ],
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
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();

      expect(find.text('REGISTER_SCREEN'), findsOneWidget);
    });

    testWidgets('displays version string', (tester) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authOverride(loggedOutAuthState),
            serverUrlOverride(),
            accessibilityOverride(),
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

      // The version text should be 'v<APP_VERSION>'.
      expect(find.textContaining(RegExp(r'^v')), findsWidgets);
    });

    testWidgets('keeps username and clears password on failed login', (
      tester,
    ) async {
      final router = _buildRouter(authState: loggedOutAuthState);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(() => _FailingLoginAuthNotifier()),
            serverUrlOverride(),
            accessibilityOverride(),
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

      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final fields = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .toList();
      expect(fields.first.controller?.text, 'alice');
      expect(fields[1].controller?.text, '');
      expect(find.text('Invalid username or password'), findsOneWidget);
    });

    testWidgets(
      'clears username on logout so a new account does not concatenate',
      (tester) async {
        // Regression: the login screen is kept alive (wantKeepAlive), so its
        // TextEditingController survives logging in. After logout, the stale
        // username remained and typing a new one appended -- producing
        // "echoqa_aliceechoqa_bob" and a failed login.
        final router = _buildRouter(authState: loggedOutAuthState);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith(() => _SwitchableAuthNotifier()),
              serverUrlOverride(),
              accessibilityOverride(),
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

        final usernameField = find.widgetWithText(TextField, 'Username');

        // User A types their name and logs in (controller now holds the name).
        await tester.enterText(usernameField, 'echoqa_alice');
        await tester.pump();
        TextFormField usernameWidget() =>
            tester.widgetList<TextFormField>(find.byType(TextFormField)).first;
        expect(usernameWidget().controller?.text, 'echoqa_alice');

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LoginScreen)),
        );
        await container.read(authProvider.notifier).login('echoqa_alice', 'pw');
        await tester.pumpAndSettle();

        // User A logs out; the kept-alive login screen rebuilds.
        await container.read(authProvider.notifier).logout();
        await tester.pumpAndSettle();

        // The stale username must be gone -- not still sitting in the field.
        expect(usernameWidget().controller?.text, '');

        // User B types their name; it must be exactly that, not appended.
        await tester.enterText(usernameField, 'echoqa_bob');
        await tester.pump();
        expect(usernameWidget().controller?.text, 'echoqa_bob');
        expect(find.text('echoqa_aliceecho_bob'), findsNothing);
      },
    );
  });
}
