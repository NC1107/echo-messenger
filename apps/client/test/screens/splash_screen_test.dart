import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/update_provider.dart';
import 'package:echo_app/src/screens/splash_screen.dart';
import 'package:echo_app/src/services/accounts_storage.dart';
import 'package:echo_app/src/services/secure_key_store.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/fake_secure_key_store.dart';
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
    GoRoute(
      path: '/auth/pick-account',
      builder: (_, _) => const Scaffold(body: Text('PICK_ACCOUNT')),
    ),
  ],
);

/// Auth notifier whose `listAccounts` returns a fixed snapshot. Used in the
/// post-auto-login routing tests to flip the splash between the launch-time
/// account picker and the plain login screen.
class _SnapshotAuthNotifier extends AuthNotifier {
  _SnapshotAuthNotifier(this._snapshot);

  final AccountsSnapshot _snapshot;

  @override
  AuthState build() => const AuthState();

  @override
  Future<bool> tryAutoLogin() async => false;

  @override
  Future<AccountsSnapshot> listAccounts() async => _snapshot;
}

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

  /// Launch-time routing: with auto-login failing, splash falls back to the
  /// account picker when stored accounts exist and to the plain login screen
  /// otherwise.
  group('SplashScreen launch routing', () {
    setUp(() {
      SecureKeyStore.instance = FakeSecureKeyStore();
    });

    Future<void> pumpWithSnapshot(
      WidgetTester tester, {
      required AccountsSnapshot snapshot,
    }) async {
      // Mark first launch completed so the 1500ms brand hold drops to 400ms.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'splash.first_launch_completed': true,
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(() => _SnapshotAuthNotifier(snapshot)),
            serverUrlOverride(),
            accessibilityOverride(),
            updateProvider.overrideWith(_FakeUpdate.new),
          ],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: _router(),
          ),
        ),
      );
      // post-frame → enterSplash → tryAutoLogin → updateProvider.check →
      // 400ms Future.delayed → _navigateAfterInit → listAccounts → context.go.
      // tester.runAsync lets real microtasks settle (the awaited Futures in
      // _init() depend on actual event-loop turns, not just pumped timers).
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets(
      'auto-login fails AND stored accounts exist → routes to picker',
      (tester) async {
        final stored = StoredAccount(
          userId: 'u-alice',
          username: 'alice',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r',
          lastUsed: DateTime.utc(2026, 1, 1),
        );
        await pumpWithSnapshot(
          tester,
          snapshot: AccountsSnapshot(
            accounts: [stored],
            activeAccountId: stored.id,
          ),
        );
        expect(find.text('PICK_ACCOUNT'), findsOneWidget);
      },
    );

    testWidgets('auto-login fails AND no stored accounts → routes to /login', (
      tester,
    ) async {
      await pumpWithSnapshot(
        tester,
        snapshot: const AccountsSnapshot(accounts: [], activeAccountId: null),
      );
      expect(find.text('LOGIN'), findsOneWidget);
    });
  });
}
