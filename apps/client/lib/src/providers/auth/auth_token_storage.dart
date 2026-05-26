part of 'auth_provider.dart';

/// Persistence layer for the auth notifier — Hive (`SecureKeyStore`),
/// SharedPreferences, and the one-shot legacy migration that copies tokens
/// off the old plaintext SharedPreferences slots into secure storage.
///
/// Lives as a `part of 'auth_provider.dart'` and as a mixin on the codegen
/// `_$AuthNotifier` base so its helpers can mutate `state` directly (the
/// Notifier `state` setter is `@protected` and only visible from within
/// mixin/subclass instance bodies — extensions can't reach it).
mixin AuthTokenStorageMixin on Notifier<AuthState> {
  /// The active server origin. Provided by [AuthNotifier].
  String get _serverUrl;

  /// Persist tokens to secure storage; userId/username to SharedPreferences.
  ///
  /// Tokens are written to [SecureKeyStore] using global (non-user-scoped)
  /// keys because this method is called BEFORE [_setUserScope]. If secure
  /// storage is unavailable (e.g. locked keyring on Linux), falls back to
  /// SharedPreferences so the session is not lost.
  ///
  /// On web the refresh token is intentionally NOT stored in any JS-accessible
  /// storage.  The browser persists it as an HttpOnly cookie (set by the
  /// server) and the cookie is sent automatically on every /api/auth/refresh
  /// request, which means storing it client-side would only create an XSS
  /// exposure without providing any benefit.
  Future<void> _storeTokens({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String username,
  }) async {
    final store = SecureKeyStore.instance;

    // Global scope (called BEFORE _setUserScope). Web: refresh token stays in
    // HttpOnly cookie; '' is the no-token sentinel.
    final shouldPersistRefresh = !kIsWeb && refreshToken.isNotEmpty;
    try {
      await store.writeGlobal(AuthNotifier._keyAccessToken, accessToken);
      if (shouldPersistRefresh) {
        await store.writeGlobal(AuthNotifier._keyRefreshToken, refreshToken);
      }
    } catch (e) {
      debugPrint('[Auth] SecureKeyStore unavailable: $e');
    }

    // Dup to SharedPreferences: belt-and-suspenders for native; web's
    // SecureKeyStore can fail post-refresh, so prefs is the recovery path.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AuthNotifier._keyAccessToken, accessToken);
      if (shouldPersistRefresh) {
        await prefs.setString(AuthNotifier._keyRefreshToken, refreshToken);
      }
      await prefs.setString(AuthNotifier._keyUserId, userId);
      await prefs.setString(AuthNotifier._keyUsername, username);

      // Per-host mirror enables login pre-fill after server switch;
      // global keys remain authoritative for the active session.
      final host = AuthNotifier._hostOf(_serverUrl);
      if (host.isNotEmpty) {
        await prefs.setString(AuthNotifier._userIdKeyFor(host), userId);
        await prefs.setString(AuthNotifier._usernameKeyFor(host), username);
      }

      // Clean up legacy password key if it exists
      await _clearLegacyCredentials(prefs);
    } catch (e) {
      debugPrint('[Auth] _storeTokens (prefs) failed: $e');
    }
  }

  /// Scope secure storage and message cache to the logged-in user.
  Future<void> _setUserScope(String userId) async {
    final host = Uri.parse(_serverUrl).host;
    SecureKeyStore.instance.setUserScope(userId, host);
    await UserDataDir.instance.setUser(userId, _serverUrl);
    try {
      await MessageCache.initForUser(userId, host);
    } catch (e) {
      // Non-fatal: web Hive/IndexedDB can fail mid-refresh; don't block login.
      debugPrint('[Auth] MessageCache.initForUser failed (non-fatal): $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Auth',
        'MessageCache.initForUser failed: $e. '
            'History may be unavailable this session.',
      );
    }
  }

  /// Clear all stored tokens from both secure storage and SharedPreferences.
  Future<void> _clearStoredTokens() async {
    // Remove tokens from secure storage (global scope).
    final store = SecureKeyStore.instance;
    await store.deleteGlobal(AuthNotifier._keyAccessToken);
    await store.deleteGlobal(AuthNotifier._keyRefreshToken);

    // Also clear prefs (tokens may exist from pre-migration / fallback writes).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AuthNotifier._keyAccessToken);
      await prefs.remove(AuthNotifier._keyRefreshToken);
      await prefs.remove(AuthNotifier._keyUserId);
      await prefs.remove(AuthNotifier._keyUsername);
      await _clearLegacyCredentials(prefs);
    } catch (e) {
      debugPrint('[Auth] _clearStoredTokens failed: $e');
    }
  }

  /// Migrate auth tokens from SharedPreferences to SecureKeyStore.
  ///
  /// Called at the start of [tryAutoLogin] before reading tokens. For each
  /// token key: if found in SharedPreferences, copies to secure storage via
  /// [SecureKeyStore.writeGlobal], then removes from SharedPreferences on
  /// success. If writeGlobal fails (e.g. keyring locked), the key is left in
  /// SharedPreferences for retry on next launch -- matching the pattern in
  /// `crypto_service.dart:_migrateFromSharedPreferences`.
  @visibleForTesting
  Future<void> migrateTokensFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final store = SecureKeyStore.instance;

    // Web: skip refresh token migration (must stay in HttpOnly cookie only).
    final keysToMigrate = kIsWeb
        ? [AuthNotifier._keyAccessToken]
        : [AuthNotifier._keyAccessToken, AuthNotifier._keyRefreshToken];

    for (final key in keysToMigrate) {
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) {
        try {
          await store.writeGlobal(key, value);
          // Web: keep prefs copy as recovery for SecureKeyStore decrypt failures.
          if (!kIsWeb) {
            await prefs.remove(key);
          }
          debugPrint(
            '[Auth] Migrated $key from SharedPreferences to secure storage',
          );
        } catch (e) {
          debugPrint(
            '[Auth] Migration of $key failed '
            '(keeping in SharedPreferences for next attempt): $e',
          );
        }
      }
    }
  }

  /// Remove legacy plaintext password storage from older versions.
  Future<void> _clearLegacyCredentials(SharedPreferences prefs) async {
    try {
      await prefs.remove('echo_auth_password');
    } catch (e) {
      debugPrint('[Auth] _clearLegacyCredentials failed: $e');
    }
  }
}
