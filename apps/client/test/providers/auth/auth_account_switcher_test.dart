import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/services/accounts_storage.dart';
import 'package:echo_app/src/services/secure_key_store.dart';
import 'package:echo_app/src/services/user_data_dir.dart';

import '../../helpers/fake_path_provider.dart';
import '../../helpers/fake_secure_key_store.dart';
import '../../helpers/mock_http_client.dart';
import '../../helpers/mock_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthNotifier multi-account flows', () {
    late MockHttpClient mockClient;
    late ProviderContainer container;
    late FakeSecureKeyStore fakeKeyStore;
    late AccountsStorage storage;
    late Directory tmpDir;

    setUpAll(() {
      registerHttpFallbackValues();
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      mockClient = MockHttpClient();
      when(() => mockClient.close()).thenReturn(null);
      fakeKeyStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeKeyStore;
      storage = AccountsStorage(secureStore: fakeKeyStore);

      tmpDir = Directory.systemTemp.createTempSync('echo_switcher_test_');
      PathProviderPlatform.instance = FakePathProvider(tmpDir.path);
      Hive.init(tmpDir.path);
      await UserDataDir.instance.init();

      container = ProviderContainer(
        overrides: [
          serverUrlProvider.overrideWith(
            () => FakeServerUrlNotifier('http://localhost:8080'),
          ),
        ],
      );
      container.read(authProvider.notifier).setAccountsStorageForTest(storage);
    });

    tearDown(() async {
      container.dispose();
      await Hive.close();
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('login appends a row instead of overwriting the list', () async {
      // Pre-seed one account.
      final existing = StoredAccount(
        userId: 'u-alice',
        username: 'alice',
        serverUrl: 'http://localhost:8080',
        refreshToken: 'r-alice',
        lastUsed: DateTime.utc(2026, 1, 1),
      );
      await storage.upsertAccount(existing);
      await storage.setActiveAccount(existing.id);

      // Now log in as bob.
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/login')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'tok-bob',
            'refresh_token': 'r-bob',
            'user_id': 'u-bob',
            'username': 'bob',
          }),
          200,
        ),
      );

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.login('bob', 'pw'),
        () => mockClient,
      );

      final snap = await notifier.listAccounts();
      expect(snap.accounts.map((a) => a.username).toSet(), {'alice', 'bob'});
      expect(
        snap.active?.username,
        'bob',
        reason: 'most-recent login becomes active',
      );
    });

    test('switchToAccount hydrates state from refresh response', () async {
      // Two stored accounts; alice is active.
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-alice',
          username: 'alice',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-alice',
          lastUsed: DateTime.utc(2026, 1, 1),
        ),
      );
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-bob',
          username: 'bob',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-bob',
          lastUsed: DateTime.utc(2026, 1, 2),
        ),
      );
      await storage.setActiveAccount('u-alice@http://localhost:8080');

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/refresh')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'tok-bob-fresh',
            'refresh_token': 'r-bob-2',
            'user_id': 'u-bob',
            'username': 'bob',
          }),
          200,
        ),
      );

      final notifier = container.read(authProvider.notifier);
      final ok = await http.runWithClient(
        () => notifier.switchToAccount('u-bob@http://localhost:8080'),
        () => mockClient,
      );

      expect(ok, isTrue);
      final st = container.read(authProvider);
      expect(st.isLoggedIn, isTrue);
      expect(st.userId, 'u-bob');
      expect(st.username, 'bob');
      expect(st.token, 'tok-bob-fresh');

      final snap = await notifier.listAccounts();
      expect(snap.activeAccountId, 'u-bob@http://localhost:8080');
    });

    test('switchToAccount returns false on refresh failure', () async {
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-stale',
          username: 'stale',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-stale',
          lastUsed: DateTime.utc(2026, 1, 1),
        ),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/refresh')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('', 401));

      final notifier = container.read(authProvider.notifier);
      final ok = await http.runWithClient(
        () => notifier.switchToAccount('u-stale@http://localhost:8080'),
        () => mockClient,
      );

      expect(ok, isFalse);
      expect(container.read(authProvider).isLoggedIn, isFalse);
    });

    test('logoutAndPickNextAccount returns the remaining account', () async {
      // Two accounts; alice active. Logout should drop alice and surface bob.
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-alice',
          username: 'alice',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-alice',
          lastUsed: DateTime.utc(2026, 1, 1),
        ),
      );
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-bob',
          username: 'bob',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-bob',
          lastUsed: DateTime.utc(2026, 1, 2),
        ),
      );
      await storage.setActiveAccount('u-alice@http://localhost:8080');

      // Stub the remote logout POST.
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/logout')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('', 200));

      final notifier = container.read(authProvider.notifier);
      // Seed auth state with the "active" user so logout has a token to send.
      await notifier.storeTokensForTest(
        accessToken: 'tok',
        refreshToken: 'r-alice',
        userId: 'u-alice',
        username: 'alice',
      );

      final next = await http.runWithClient(
        () => notifier.logoutAndPickNextAccount(),
        () => mockClient,
      );

      expect(next, isNotNull);
      expect(next!.userId, 'u-bob');
      final snap = await notifier.listAccounts();
      // Alice should be gone after logout-with-forget.
      expect(snap.accounts.map((a) => a.userId), ['u-bob']);
    });

    test(
      'logoutAndPickNextAccount returns null when only one account stored',
      () async {
        await storage.upsertAccount(
          StoredAccount(
            userId: 'u-only',
            username: 'only',
            serverUrl: 'http://localhost:8080',
            refreshToken: 'r',
            lastUsed: DateTime.utc(2026, 1, 1),
          ),
        );
        await storage.setActiveAccount('u-only@http://localhost:8080');

        when(
          () => mockClient.post(
            any(that: predicate<Uri>((u) => u.path == '/api/auth/logout')),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer((_) async => http.Response('', 200));

        final notifier = container.read(authProvider.notifier);
        await notifier.storeTokensForTest(
          accessToken: 'tok',
          refreshToken: 'r',
          userId: 'u-only',
          username: 'only',
        );

        final next = await http.runWithClient(
          () => notifier.logoutAndPickNextAccount(),
          () => mockClient,
        );

        expect(next, isNull);
        final snap = await notifier.listAccounts();
        expect(snap.accounts, isEmpty);
      },
    );
  });
}
