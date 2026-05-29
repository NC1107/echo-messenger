import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/screens/auth/account_picker_screen.dart';
import 'package:echo_app/src/services/accounts_storage.dart';
import 'package:echo_app/src/services/secure_key_store.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/fake_secure_key_store.dart';
import '../../helpers/mock_providers.dart';

/// Track `switchToAccount` calls so tests can assert that tapping a row
/// dispatches the right id. Returns [resultByAccountId] when present, else
/// falls back to true (success).
class _RecordingAuthNotifier extends AuthNotifier {
  _RecordingAuthNotifier({
    required this.storage,
    this.resultByAccountId = const <String, bool>{},
  });

  final AccountsStorage storage;
  final Map<String, bool> resultByAccountId;
  final List<String> switchCalls = <String>[];

  @override
  AuthState build() => const AuthState();

  @override
  AccountsStorage get accountsStorage => storage;

  @override
  Future<AccountsSnapshot> listAccounts() => storage.load();

  @override
  Future<bool> switchToAccount(String accountId) async {
    switchCalls.add(accountId);
    return resultByAccountId[accountId] ?? true;
  }
}

/// Helper to count `clear()` invocations.
class _CountingStorage extends AccountsStorage {
  _CountingStorage({super.secureStore});
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    await super.clear();
  }
}

/// Stub Chat notifier so the picker's `chatProvider.notifier.clear()` call
/// doesn't pull in the real provider's group-crypto + timer setup.
class _FakeChat extends Chat {
  @override
  ChatState build() => const ChatState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccountPickerScreen', () {
    late FakeSecureKeyStore fakeKeyStore;
    late AccountsStorage storage;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      fakeKeyStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeKeyStore;
      storage = AccountsStorage(secureStore: fakeKeyStore);
    });

    /// Mount the picker inside a GoRouter so `context.go('/home')` resolves
    /// to a routable page. Tracks the location in [locations] so tests can
    /// assert post-tap navigation without scraping widgets.
    Future<List<String>> pumpPicker(
      WidgetTester tester, {
      _RecordingAuthNotifier? authNotifier,
      AccountsStorage? overrideStorage,
    }) async {
      final locations = <String>[];
      final activeStorage = overrideStorage ?? storage;
      final router = GoRouter(
        initialLocation: '/auth/pick-account',
        observers: [_LocationObserver(onPush: (loc) => locations.add(loc))],
        routes: [
          GoRoute(
            path: '/auth/pick-account',
            builder: (_, _) => const AccountPickerScreen(),
          ),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Scaffold(body: Text('LOGIN_SCREEN')),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('HOME_SCREEN')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
              () =>
                  authNotifier ??
                  _RecordingAuthNotifier(storage: activeStorage),
            ),
            serverUrlOverride('http://localhost:8080'),
            // Picker tears down per-user state before swapping identities.
            // Override the side-effecting providers so the test doesn't open
            // real sockets or touch crypto state.
            webSocketOverride(),
            cryptoOverride(),
            chatProvider.overrideWith(_FakeChat.new),
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
      return locations;
    }

    StoredAccount aliceFixture() => StoredAccount(
      userId: 'u-alice',
      username: 'alice',
      serverUrl: 'http://localhost:8080',
      refreshToken: 'r-a',
      lastUsed: DateTime.utc(2026, 1, 1),
    );

    StoredAccount bobFixture() => StoredAccount(
      userId: 'u-bob',
      username: 'bob',
      serverUrl: 'http://localhost:8080',
      refreshToken: 'r-b',
      lastUsed: DateTime.utc(2026, 1, 2),
    );

    testWidgets('renders one row per stored account with username and host', (
      tester,
    ) async {
      await storage.upsertAccount(aliceFixture());
      await storage.upsertAccount(bobFixture());

      await pumpPicker(tester);

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      // Brand header + welcome copy.
      expect(find.text('Welcome back'), findsOneWidget);
      // Add-account row and sign-out footer are present.
      expect(find.text('Add another account'), findsOneWidget);
      expect(find.text('Not your account? Sign out'), findsOneWidget);
    });

    testWidgets('tapping a row calls switchToAccount with that id', (
      tester,
    ) async {
      await storage.upsertAccount(aliceFixture());
      await storage.upsertAccount(bobFixture());

      final notifier = _RecordingAuthNotifier(storage: storage);
      await pumpPicker(tester, authNotifier: notifier);

      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();

      // The persisted id is "{userId}@{serverUrl}".
      expect(notifier.switchCalls.single, 'u-alice@http://localhost:8080');
    });

    testWidgets('successful switch navigates to /home', (tester) async {
      await storage.upsertAccount(aliceFixture());

      final notifier = _RecordingAuthNotifier(
        storage: storage,
        resultByAccountId: const {'u-alice@http://localhost:8080': true},
      );
      await pumpPicker(tester, authNotifier: notifier);

      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();

      expect(find.text('HOME_SCREEN'), findsOneWidget);
    });

    testWidgets('failed switch shows snackbar and routes to /login', (
      tester,
    ) async {
      await storage.upsertAccount(aliceFixture());

      final notifier = _RecordingAuthNotifier(
        storage: storage,
        resultByAccountId: const {'u-alice@http://localhost:8080': false},
      );
      await pumpPicker(tester, authNotifier: notifier);

      await tester.tap(find.text('alice'));
      // Pump enough frames for the snackbar to mount before routing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining("Couldn't refresh session"), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });

    testWidgets('tapping "Add another account" routes to /login', (
      tester,
    ) async {
      await storage.upsertAccount(aliceFixture());

      await pumpPicker(tester);

      await tester.tap(find.text('Add another account'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });

    testWidgets(
      'tapping "Sign out" clears the accounts storage and routes to /login',
      (tester) async {
        final countingStorage = _CountingStorage(secureStore: fakeKeyStore);
        await countingStorage.upsertAccount(aliceFixture());

        final notifier = _RecordingAuthNotifier(storage: countingStorage);
        await pumpPicker(
          tester,
          authNotifier: notifier,
          overrideStorage: countingStorage,
        );

        await tester.tap(find.text('Not your account? Sign out'));
        await tester.pumpAndSettle();

        expect(countingStorage.clearCalls, 1);
        expect(find.text('LOGIN_SCREEN'), findsOneWidget);
      },
    );
  });
}

/// Tiny [NavigatorObserver] that records pushed routes' names so tests can
/// assert nav order. Kept private to the test file.
class _LocationObserver extends NavigatorObserver {
  _LocationObserver({required this.onPush});

  final void Function(String location) onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = route.settings.name;
    if (name != null) onPush(name);
  }
}
