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
import 'package:echo_app/src/services/secure_key_store.dart';
import 'package:echo_app/src/services/user_data_dir.dart';

import '../helpers/fake_path_provider.dart';
import '../helpers/fake_secure_key_store.dart';
import '../helpers/mock_http_client.dart';

void main() {
  group('AuthState', () {
    test('initial state is logged out with no token or userId', () {
      const state = AuthState();
      expect(state.isLoggedIn, isFalse);
      expect(state.token, isNull);
      expect(state.userId, isNull);
      expect(state.username, isNull);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
    });

    test('copyWith preserves values', () {
      const state = AuthState(
        isLoggedIn: true,
        userId: '123',
        username: 'alice',
        token: 'tok',
      );
      final copied = state.copyWith(error: 'test');
      expect(copied.isLoggedIn, isTrue);
      expect(copied.userId, '123');
      expect(copied.username, 'alice');
      expect(copied.error, 'test');
    });

    test('default AuthState represents logged out', () {
      const state = AuthState();
      expect(state.isLoggedIn, isFalse);
      expect(state.isLoading, isFalse);
    });
  });

  group('Token migration from SharedPreferences to SecureKeyStore', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
    });

    test('migrates tokens from SharedPreferences to SecureKeyStore', () async {
      SharedPreferences.setMockInitialValues({
        'echo_auth_access_token': 'old-access-tok',
        'echo_auth_refresh_token': 'old-refresh-tok',
        'echo_auth_user_id': 'user-1',
        'echo_auth_username': 'alice',
      });

      // Create a minimal AuthNotifier just to call the migration method.
      // We use a ProviderContainer so Riverpod is happy, but we only need
      // to exercise migrateTokensFromSharedPreferences which does not
      // touch the network.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(authProvider.notifier);

      await notifier.migrateTokensFromSharedPreferences();

      // Tokens should now be in secure storage
      expect(
        await fakeStore.readGlobal('echo_auth_access_token'),
        'old-access-tok',
      );
      expect(
        await fakeStore.readGlobal('echo_auth_refresh_token'),
        'old-refresh-tok',
      );

      // Tokens should be removed from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_auth_access_token'), isNull);
      expect(prefs.getString('echo_auth_refresh_token'), isNull);

      // Non-sensitive data stays in SharedPreferences
      expect(prefs.getString('echo_auth_user_id'), 'user-1');
      expect(prefs.getString('echo_auth_username'), 'alice');
    });

    test('migration is idempotent', () async {
      SharedPreferences.setMockInitialValues({
        'echo_auth_refresh_token': 'refresh-tok',
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(authProvider.notifier);

      // Run migration twice
      await notifier.migrateTokensFromSharedPreferences();
      await notifier.migrateTokensFromSharedPreferences();

      // Token is in secure storage exactly once (value unchanged)
      expect(
        await fakeStore.readGlobal('echo_auth_refresh_token'),
        'refresh-tok',
      );

      // SharedPreferences is clean
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_auth_refresh_token'), isNull);
    });

    test('skips empty/null values in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({'echo_auth_access_token': ''});

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(authProvider.notifier);

      await notifier.migrateTokensFromSharedPreferences();

      // Empty string should NOT be migrated
      expect(await fakeStore.readGlobal('echo_auth_access_token'), isNull);
    });

    test('migration with no tokens in SharedPreferences is a no-op', () async {
      SharedPreferences.setMockInitialValues({});

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(authProvider.notifier);

      await notifier.migrateTokensFromSharedPreferences();

      // Secure storage should be empty
      expect(fakeStore.dump, isEmpty);
    });
  });

  group('AuthNotifier HTTP', () {
    late MockHttpClient mockClient;
    late ProviderContainer container;
    late FakeSecureKeyStore fakeKeyStore;
    late Directory tmpDir;

    setUpAll(() {
      registerHttpFallbackValues();
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      mockClient = MockHttpClient();
      when(() => mockClient.close()).thenReturn(null);
      fakeKeyStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeKeyStore;

      // Set up fake path provider so UserDataDir.init() works in tests.
      tmpDir = Directory.systemTemp.createTempSync('echo_auth_test_');
      PathProviderPlatform.instance = FakePathProvider(tmpDir.path);
      Hive.init(tmpDir.path);
      await UserDataDir.instance.init();

      container = ProviderContainer(
        overrides: [
          serverUrlProvider.overrideWith((ref) {
            final n = ServerUrlNotifier();
            n.state = 'http://localhost:8080';
            return n;
          }),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await Hive.close();
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('login() returns 200 sets logged-in state', () async {
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
            'access_token': 'tok-123',
            'refresh_token': 'ref-456',
            'user_id': 'uid-1',
            'username': 'dev',
          }),
          200,
        ),
      );

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.login('dev', 'pass'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isTrue);
      expect(st.userId, 'uid-1');
      expect(st.username, 'dev');
      expect(st.token, 'tok-123');
    });

    test('login() returns 401 stays logged out with error', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/login')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'error': 'Invalid credentials'}), 401),
      );

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.login('dev', 'wrong'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);
      expect(st.error, isNotNull);
      expect(st.error, contains('Invalid'));
    });

    test('login() network error stays logged out with error', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/login')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.login('dev', 'pass'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);
      expect(st.error, isNotNull);
    });

    test('register() returns 201 sets logged-in state', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/register')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'reg-tok',
            'refresh_token': 'reg-ref',
            'user_id': 'new-uid',
          }),
          201,
        ),
      );

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.register('newuser', 'pass123'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isTrue);
      expect(st.userId, 'new-uid');
    });

    test('register() returns 409 stays logged out with error', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/register')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'error': 'Username already taken'}), 409),
      );

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.register('taken', 'pass'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);
      expect(st.error, isNotNull);
      expect(st.error, contains('already taken'));
    });

    test('register() network error sets error', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/register')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(authProvider.notifier);
      await http.runWithClient(
        () => notifier.register('user', 'pass'),
        () => mockClient,
      );

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);
      expect(st.error, isNotNull);
    });

    test('logout() clears state and tokens', () async {
      // Pre-set logged-in state with tokens stored.
      final notifier = container.read(authProvider.notifier);
      notifier.state = const AuthState(
        isLoggedIn: true,
        userId: 'uid-1',
        username: 'dev',
        token: 'tok-123',
        refreshToken: 'ref-456',
      );
      await fakeKeyStore.writeGlobal('echo_auth_access_token', 'tok-123');
      await fakeKeyStore.writeGlobal('echo_auth_refresh_token', 'ref-456');

      await notifier.logout();

      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);
      expect(st.token, isNull);
      expect(st.userId, isNull);

      // Tokens should be cleared from SecureKeyStore.
      expect(await fakeKeyStore.readGlobal('echo_auth_access_token'), isNull);
      expect(await fakeKeyStore.readGlobal('echo_auth_refresh_token'), isNull);
    });

    test('tryAutoLogin() with refresh token restores session', () async {
      // Store a refresh token and user info.
      await fakeKeyStore.writeGlobal('echo_auth_refresh_token', 'stored-ref');
      SharedPreferences.setMockInitialValues({
        'echo_auth_user_id': 'uid-1',
        'echo_auth_username': 'dev',
      });

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
            'access_token': 'new-tok',
            'refresh_token': 'new-ref',
            'user_id': 'uid-1',
            'username': 'dev',
          }),
          200,
        ),
      );

      final notifier = container.read(authProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.tryAutoLogin(),
        () => mockClient,
      );

      expect(result, isTrue);
      final st = container.read(authProvider);
      expect(st.isLoggedIn, isTrue);
      expect(st.token, 'new-tok');
    });

    test('tryAutoLogin() refresh fails 401 clears tokens', () async {
      await fakeKeyStore.writeGlobal('echo_auth_refresh_token', 'expired-ref');
      SharedPreferences.setMockInitialValues({
        'echo_auth_user_id': 'uid-1',
        'echo_auth_username': 'dev',
      });

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/refresh')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('Unauthorized', 401));

      final notifier = container.read(authProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.tryAutoLogin(),
        () => mockClient,
      );

      expect(result, isFalse);
      final st = container.read(authProvider);
      expect(st.isLoggedIn, isFalse);

      // Tokens should be cleared.
      expect(await fakeKeyStore.readGlobal('echo_auth_refresh_token'), isNull);
    });

    test('tryAutoLogin() no stored tokens returns false', () async {
      // Empty keystore and SharedPreferences.
      SharedPreferences.setMockInitialValues({});

      final notifier = container.read(authProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.tryAutoLogin(),
        () => mockClient,
      );

      expect(result, isFalse);
      expect(container.read(authProvider).isLoggedIn, isFalse);
    });

    test('refreshAccessToken() success updates token', () async {
      final notifier = container.read(authProvider.notifier);
      notifier.state = const AuthState(
        isLoggedIn: true,
        userId: 'uid-1',
        username: 'dev',
        token: 'old-tok',
        refreshToken: 'valid-ref',
      );

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
            'access_token': 'refreshed-tok',
            'refresh_token': 'new-ref',
          }),
          200,
        ),
      );

      final result = await http.runWithClient(
        () => notifier.refreshAccessToken(),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(container.read(authProvider).token, 'refreshed-tok');
    });

    test('refreshAccessToken() failure triggers logout', () async {
      final notifier = container.read(authProvider.notifier);
      notifier.state = const AuthState(
        isLoggedIn: true,
        userId: 'uid-1',
        username: 'dev',
        token: 'old-tok',
        refreshToken: 'expired-ref',
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/refresh')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('Unauthorized', 401));

      final result = await http.runWithClient(
        () => notifier.refreshAccessToken(),
        () => mockClient,
      );

      expect(result, isFalse);
      expect(container.read(authProvider).isLoggedIn, isFalse);
    });

    test('authenticatedRequest() passes through 200', () async {
      final notifier = container.read(authProvider.notifier);
      notifier.state = const AuthState(
        isLoggedIn: true,
        token: 'valid-tok',
        refreshToken: 'ref',
      );

      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/users/me')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('{"id":"me"}', 200));

      final response = await http.runWithClient(
        () => notifier.authenticatedRequest(
          (token) => http.get(
            Uri.parse('http://localhost:8080/api/users/me'),
            headers: {'Authorization': 'Bearer $token'},
          ),
        ),
        () => mockClient,
      );

      expect(response.statusCode, 200);
    });

    test('authenticatedRequest() retries on 401 after refresh', () async {
      final notifier = container.read(authProvider.notifier);
      notifier.state = const AuthState(
        isLoggedIn: true,
        token: 'expired-tok',
        refreshToken: 'valid-ref',
      );

      // First call: 401
      var callCount = 0;
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/data')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return http.Response('Unauthorized', 401);
        }
        return http.Response('{"ok": true}', 200);
      });

      // Refresh succeeds
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/auth/refresh')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({'access_token': 'new-tok', 'refresh_token': 'new-ref'}),
          200,
        ),
      );

      final response = await http.runWithClient(
        () => notifier.authenticatedRequest(
          (token) => http.get(
            Uri.parse('http://localhost:8080/api/data'),
            headers: {'Authorization': 'Bearer $token'},
          ),
        ),
        () => mockClient,
      );

      expect(response.statusCode, 200);
      expect(callCount, 2, reason: 'should have retried after 401');
    });
  });
}
