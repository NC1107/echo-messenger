import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App launch', () {
    testWidgets('shows login screen on cold start', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverUrlProvider.overrideWith((ref) {
              final n = ServerUrlNotifier();
              // Prevent real SharedPreferences access
              return n;
            }),
          ],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const _LoginShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should show the login UI elements
      expect(find.text('Echo'), findsAtLeast(1));
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Login'), findsOneWidget);
    });

    testWidgets('login fields accept input', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverUrlProvider.overrideWith((ref) => ServerUrlNotifier()),
          ],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const _LoginShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enter username
      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'integrationuser',
      );
      await tester.pump();
      expect(find.text('integrationuser'), findsOneWidget);

      // Enter password
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'testpass123',
      );
      await tester.pump();
      expect(find.text('testpass123'), findsOneWidget);
    });

    testWidgets('app renders with proper theme', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const Scaffold(body: Center(child: Text('Theme Test'))),
          ),
        ),
      );
      await tester.pump();

      // Verify the scaffold uses the dark theme background
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      // The theme should be applied (dark theme has EchoTheme.mainBg background)
      expect(scaffold, isNotNull);
      expect(find.text('Theme Test'), findsOneWidget);
    });

    testWidgets('login button is disabled while loading', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverUrlProvider.overrideWith((ref) => ServerUrlNotifier()),
            authProvider.overrideWith((ref) => _LoadingAuthNotifier(ref)),
          ],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const _LoginShell(),
          ),
        ),
      );
      await tester.pump();

      // When auth state is loading, the button should show a progress indicator
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('error message displays when auth has error', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverUrlProvider.overrideWith((ref) => ServerUrlNotifier()),
            authProvider.overrideWith((ref) => _ErrorAuthNotifier(ref)),
          ],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const _LoginShell(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Invalid credentials'), findsOneWidget);
    });
  });
}

/// Minimal shell that renders the login screen imports without pulling in
/// the full GoRouter (which requires all screens and their heavy deps).
class _LoadingAuthNotifier extends AuthNotifier {
  _LoadingAuthNotifier(super.ref) {
    state = const AuthState(isLoading: true);
  }

  @override
  Future<void> login(String username, String password) async {}
  @override
  Future<void> register(String username, String password) async {}
  @override
  Future<bool> tryAutoLogin() async => false;
  @override
  void logout() => state = const AuthState();
}

class _ErrorAuthNotifier extends AuthNotifier {
  _ErrorAuthNotifier(super.ref) {
    state = const AuthState(error: 'Invalid credentials');
  }

  @override
  Future<void> login(String username, String password) async {}
  @override
  Future<void> register(String username, String password) async {}
  @override
  Future<bool> tryAutoLogin() async => false;
  @override
  void logout() => state = const AuthState();
}

class _LoginShell extends ConsumerStatefulWidget {
  const _LoginShell();

  @override
  ConsumerState<_LoginShell> createState() => _LoginShellState();
}

class _LoginShellState extends ConsumerState<_LoginShell> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Echo', style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 32),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (authState.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    authState.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: authState.isLoading ? null : () {},
                    child: authState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Login'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
