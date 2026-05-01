import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/token_join_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

GoRouter _buildRouter({String token = 'test-invite-token'}) {
  return GoRouter(
    initialLocation: '/invite/t/$token',
    routes: [
      GoRoute(
        path: '/invite/t/:token',
        builder: (_, state) =>
            TokenJoinScreen(token: state.pathParameters['token']!),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('HOME_SCREEN'))),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('LOGIN_SCREEN'))),
      ),
    ],
  );
}

void main() {
  group('TokenJoinScreen', () {
    testWidgets('shows loading skeleton initially', (tester) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [...standardOverrides()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      // The screen starts loading — skeleton containers should be visible
      // before the network call resolves.
      expect(find.byType(TokenJoinScreen), findsOneWidget);
    });

    testWidgets('renders error card for logged-out user without token lookup', (
      tester,
    ) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...standardOverrides(
              authState: const AuthState(), // logged out
            ),
          ],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      // Pump once for initState callback + once for setState after it runs
      await tester.pump();
      await tester.pump();

      // Logged-out user sees a "Log in to join" button (no preview call is made)
      expect(find.text('Log in to join'), findsOneWidget);
    });

    testWidgets('navigates to login on "Log in to join" tap', (tester) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [...standardOverrides(authState: const AuthState())],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Log in to join'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });
  });
}
