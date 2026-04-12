import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

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
}
