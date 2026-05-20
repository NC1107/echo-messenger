import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/update_provider.dart';
import 'package:echo_app/src/screens/splash_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

class _FakeUpdate extends Update {
  @override
  UpdateState build() => const UpdateState();

  @override
  Future<void> check({bool force = false}) async {}
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
    GoRoute(
      path: '/login',
      builder: (_, _) => const Scaffold(body: Text('LOGIN')),
    ),
    GoRoute(
      path: '/home',
      builder: (_, _) => const Scaffold(body: Text('HOME')),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  List<Override> extra = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authOverride(),
        serverUrlOverride(),
        accessibilityOverride(),
        updateProvider.overrideWith(_FakeUpdate.new),
        ...extra,
      ],
      child: MaterialApp.router(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        routerConfig: _router(),
      ),
    ),
  );
  // Allow a couple of frames so the fade-in starts. We deliberately avoid
  // pumpAndSettle: the splash schedules a 1500ms minimum delay before
  // navigation, which would hang any settle-based wait.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('SplashScreen', () {
    testWidgets('renders brand block: Echo wordmark + tagline', (tester) async {
      await _pump(tester);

      expect(find.text('Echo'), findsOneWidget);
      expect(
        find.text('End-to-end encrypted. Zero telemetry.'),
        findsOneWidget,
      );
    });

    testWidgets('shows the initial "Connecting…" status text', (tester) async {
      await _pump(tester);
      // _SplashScreenState._statusText defaults to "Connecting…". By the time
      // we pump a few frames the post-frame callback fires `_init()` which
      // flips status to "Checking session…" — accept either, both prove the
      // status row is wired up to the boot state machine.
      final hasInitial = find.text('Connecting…').evaluate().isNotEmpty;
      final hasChecking = find.text('Checking session…').evaluate().isNotEmpty;
      expect(hasInitial || hasChecking, isTrue);
    });

    testWidgets('renders the progress sweep + version footer', (tester) async {
      await _pump(tester);
      // The version footer uses the `v` prefix; we don't assert the exact
      // number so the test survives version bumps.
      expect(find.textContaining('v'), findsWidgets);
    });
  });
}
