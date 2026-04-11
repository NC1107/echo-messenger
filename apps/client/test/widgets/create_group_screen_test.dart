import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/screens/create_group_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: '/create-group',
    routes: [
      GoRoute(
        path: '/create-group',
        builder: (_, _) => const CreateGroupScreen(),
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
  group('CreateGroupScreen', () {
    testWidgets('renders group creation form', (tester) async {
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
      await tester.pumpAndSettle();

      expect(find.text('Create Group'), findsOneWidget);
    });

    testWidgets('renders group name text field', (tester) async {
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
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Group Name'), findsOneWidget);
    });

    testWidgets('renders description text field', (tester) async {
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
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, 'Description (optional)'),
        findsOneWidget,
      );
    });

    testWidgets('can type in group name', (tester) async {
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
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Group Name'),
        'My Test Group',
      );
      await tester.pump();

      expect(find.text('My Test Group'), findsOneWidget);
    });

    testWidgets('has private/public visibility toggle', (tester) async {
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
      await tester.pumpAndSettle();

      expect(find.text('Private'), findsOneWidget);
      expect(find.text('Public'), findsOneWidget);
    });
  });
}
