import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart' show BackgroundService;
import '../services/debug_log_service.dart';
import '../services/message_cache.dart';
import '../services/secure_key_store.dart';
import '../services/user_data_dir.dart';
import 'server_url_provider.dart';

const _kJsonHeaders = {'Content-Type': 'application/json'};

class AuthState {
  final bool isLoggedIn;
  final String? userId;
  final String? username;
  final String? token;
  final String? refreshToken;
  final String? avatarUrl;
  final String? error;
  final bool isLoading;

  /// The user's chosen presence status: "online", "away", "dnd", "invisible".
  final String presenceStatus;

  /// Whether the onboarding wizard has been completed on this device.
  /// False for newly registered accounts that haven't gone through onboarding.
  final bool onboardingCompleted;

  const AuthState({
    this.isLoggedIn = false,
    this.userId,
    this.username,
    this.token,
    this.refreshToken,
    this.avatarUrl,
    this.error,
    this.isLoading = false,
    this.presenceStatus = 'online',
    this.onboardingCompleted = true,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    String? userId,
    String? username,
    String? token,
    String? refreshToken,
    String? avatarUrl,
    String? error,
    bool? isLoading,
    String? presenceStatus,
    bool? onboardingCompleted,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      token: token ?? this.token,
      refreshToken: refreshToken ?? this.refreshToken,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      error: error,
      isLoading: isLoading ?? this.isLoading,
      presenceStatus: presenceStatus ?? this.presenceStatus,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final Ref ref;

  /// Lock to prevent concurrent token refresh calls. When a refresh is
  /// in-flight, subsequent callers await the same Future instead of
  /// sending duplicate refresh requests (which would fail due to
  /// server-side token rotation consuming the token on first use).
  Completer<bool>? _refreshLock;

  AuthNotifier(this.ref) : super(const AuthState());

  static const _keyAccessToken = 'echo_auth_access_token';
  static const _keyRefreshToken = 'echo_auth_refresh_token';
  static const _keyUserId = 'echo_auth_user_id';
  static const _keyUsername = 'echo_auth_username';

  String get _serverUrl => ref.read(serverUrlProvider);

  /// Try to auto-login using stored refresh token.
  ///
  /// Reads the refresh token from [SecureKeyStore] (global scope), falling
  /// back to SharedPreferences for pre-migration installs. Calls the refresh
  /// endpoint to get a new access token and restores the session. If the
  /// refresh fails (expired, revoked, or server unreachable), clears stored
  /// tokens and returns false so the user must log in manually.
  Future<bool> tryAutoLogin() async {
    try {
      // Migrate tokens from SharedPreferences to secure storage if needed.
      await migrateTokensFromSharedPreferences();

      final prefs = await SharedPreferences.getInstance();
      final storedUserId = prefs.getString(_keyUserId);
      final storedUsername = prefs.getString(_keyUsername);

      // Read refresh token from secure storage first, fall back to prefs
      // (covers the case where secure storage was unavailable during
      // migration or during a previous _storeTokens fallback write).
      String? storedRefreshToken;
      try {
        storedRefreshToken = await SecureKeyStore.instance.readGlobal(
          _keyRefreshToken,
        );
      } catch (_) {
        // Secure storage unavailable -- fall through to prefs.
      }
      storedRefreshToken ??= prefs.getString(_keyRefreshToken);

      if (storedRefreshToken == null || storedRefreshToken.isEmpty) {
        // No refresh token stored -- check for legacy access token as fallback
        String? legacyToken;
        try {
          legacyToken = await SecureKeyStore.instance.readGlobal(
            _keyAccessToken,
          );
        } catch (_) {}
        legacyToken ??= prefs.getString(_keyAccessToken);
        if (legacyToken != null &&
            legacyToken.isNotEmpty &&
            storedUserId != null &&
            storedUsername != null) {
          // Legacy mode: we have an access token but no refresh token.
          // Restore the session optimistically -- it may be expired, but
          // individual API calls will handle 401 gracefully.
          await _setUserScope(storedUserId);
          final legacyOnboardingDone =
              prefs.getBool('onboarding_completed') ?? true;
          state = AuthState(
            isLoggedIn: true,
            userId: storedUserId,
            username: storedUsername,
            token: legacyToken,
            onboardingCompleted: legacyOnboardingDone,
          );
          return true;
        }

        // Also handle old-style stored password credentials by clearing them
        await _clearLegacyCredentials(prefs);
        return false;
      }

      // We have a refresh token -- attempt to get a new access token
      state = state.copyWith(isLoading: true);

      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/auth/refresh'),
            headers: _kJsonHeaders,
            body: jsonEncode({'refresh_token': storedRefreshToken}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;
        final newRefreshToken =
            data['refresh_token'] as String? ?? storedRefreshToken;
        final userId = data['user_id'] as String? ?? storedUserId ?? '';
        final username = data['username'] as String? ?? storedUsername ?? '';

        // Persist new tokens BEFORE any other async work. The server
        // already revoked the old refresh token during rotation, so if
        // _setUserScope throws (e.g. Hive/IndexedDB error on web) or the
        // page is refreshed before we finish, the new token is safe in
        // localStorage and the next auto-login attempt will succeed.
        await _storeTokens(
          accessToken: newAccessToken,
          refreshToken: newRefreshToken,
          userId: userId,
          username: username,
        );

        await _setUserScope(userId);
        final onboardingDone = prefs.getBool('onboarding_completed') ?? true;
        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: newAccessToken,
          refreshToken: newRefreshToken,
          onboardingCompleted: onboardingDone,
        );
        return true;
      } else {
        // Refresh failed -- clear stored tokens, user must log in again
        await _clearStoredTokens();
        state = const AuthState();
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] tryAutoLogin failed: $e');
      // Network error or other failure -- don't clear tokens, just fail
      // so user can retry when connectivity is restored.
      state = const AuthState();
      return false;
    }
  }

  /// Attempt to refresh the access token using the stored refresh token.
  ///
  /// Returns true if the refresh succeeded and state has been updated with
  /// a new access token. Returns false if the refresh failed (in which case
  /// the user is logged out).
  Future<bool> refreshAccessToken() async {
    // If a refresh is already in-flight, coalesce with it instead of
    // sending a duplicate request (server-side token rotation consumes
    // the token on first use, so the second request would fail).
    if (_refreshLock != null) {
      return _refreshLock!.future;
    }
    _refreshLock = Completer<bool>();

    try {
      final result = await _doRefreshAccessToken();
      _refreshLock!.complete(result);
      return result;
    } catch (e) {
      _refreshLock!.complete(false);
      rethrow;
    } finally {
      _refreshLock = null;
    }
  }

  Future<bool> _doRefreshAccessToken() async {
    final currentRefreshToken = state.refreshToken;
    if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
      return false;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/auth/refresh'),
            headers: _kJsonHeaders,
            body: jsonEncode({'refresh_token': currentRefreshToken}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;
        final newRefreshToken =
            data['refresh_token'] as String? ?? currentRefreshToken;

        state = state.copyWith(
          token: newAccessToken,
          refreshToken: newRefreshToken,
        );

        await _storeTokens(
          accessToken: newAccessToken,
          refreshToken: newRefreshToken,
          userId: state.userId ?? '',
          username: state.username ?? '',
        );
        return true;
      } else {
        // Refresh failed -- force logout
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] refreshAccessToken failed: $e');
      return false;
    }
  }

  /// Make an authenticated HTTP request with automatic 401 retry.
  ///
  /// If the request returns 401, attempts to refresh the access token once
  /// and retries the request. If the refresh fails, triggers logout.
  ///
  /// [requestFn] receives the current access token and should return the
  /// HTTP response. It will be called once normally, and a second time with
  /// a refreshed token if the first attempt returns 401.
  ///
  /// A 15-second timeout is applied to each individual HTTP call. Callers
  /// should catch [TimeoutException] (from dart:async) alongside other errors
  /// if they need custom timeout messaging.
  Future<http.Response> authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    const timeout = Duration(seconds: 15);
    final token = state.token ?? '';
    final response = await requestFn(token).timeout(timeout);

    if (response.statusCode == 401) {
      // Attempt token refresh
      final refreshed = await refreshAccessToken();
      if (refreshed) {
        // Retry with new token
        return requestFn(state.token ?? '').timeout(timeout);
      }
      // Refresh failed -- logout already triggered by refreshAccessToken
    }

    return response;
  }

  /// Persist tokens to secure storage; userId/username to SharedPreferences.
  ///
  /// Tokens are written to [SecureKeyStore] using global (non-user-scoped)
  /// keys because this method is called BEFORE [_setUserScope]. If secure
  /// storage is unavailable (e.g. locked keyring on Linux), falls back to
  /// SharedPreferences so the session is not lost.
  Future<void> _storeTokens({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String username,
  }) async {
    final store = SecureKeyStore.instance;

    // Write tokens to secure storage (global scope -- no user prefix).
    try {
      await store.writeGlobal(_keyAccessToken, accessToken);
      await store.writeGlobal(_keyRefreshToken, refreshToken);
    } catch (e) {
      debugPrint('[Auth] SecureKeyStore unavailable: $e');
    }

    // Always write to SharedPreferences as well. On web, SecureKeyStore
    // uses Web Crypto + encrypted localStorage which can fail to read
    // back after a page refresh, causing unexpected logouts. Keeping a
    // copy in SharedPreferences guarantees tryAutoLogin can recover.
    // On native platforms the duplication is harmless (belt & suspenders).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccessToken, accessToken);
      await prefs.setString(_keyRefreshToken, refreshToken);
      await prefs.setString(_keyUserId, userId);
      await prefs.setString(_keyUsername, username);

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
      // Non-fatal: fall back to the default shared message cache.
      // On web, Hive/IndexedDB box close/reopen can fail during
      // page refresh; this must not prevent login.
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
    await store.deleteGlobal(_keyAccessToken);
    await store.deleteGlobal(_keyRefreshToken);

    // Remove everything from SharedPreferences (tokens may exist there
    // from pre-migration installs or secure-storage fallback writes).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyAccessToken);
      await prefs.remove(_keyRefreshToken);
      await prefs.remove(_keyUserId);
      await prefs.remove(_keyUsername);
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

    for (final key in [_keyAccessToken, _keyRefreshToken]) {
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) {
        try {
          await store.writeGlobal(key, value);
          // On web, keep tokens in SharedPreferences as a reliable fallback.
          // SecureKeyStore on web uses Web Crypto API encryption which can
          // fail to decrypt after page refresh in some browsers, so
          // SharedPreferences (plain localStorage) is the safety net.
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

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/auth/register'),
            headers: _kJsonHeaders,
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final accessToken = data['access_token'] as String;
        // Server may or may not return refresh_token (backward compat)
        final refreshToken = data['refresh_token'] as String?;
        final userId = data['user_id'] as String;

        await _storeTokens(
          accessToken: accessToken,
          refreshToken: refreshToken ?? '',
          userId: userId,
          username: username,
        );

        await _setUserScope(userId);
        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: accessToken,
          refreshToken: refreshToken,
          onboardingCompleted: false,
        );
      } else {
        String errorMsg = 'Registration failed';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (e) {
          debugPrint('[Auth] register response parse failed: $e');
          errorMsg = 'Server error (${response.statusCode})';
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      final msg = e is TimeoutException
          ? 'Cannot reach server. Check your connection.'
          : e.toString().contains('FormatException')
          ? 'Cannot reach server. Check your connection.'
          : e.toString();
      state = state.copyWith(isLoading: false, error: msg);
    }
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/auth/login'),
            headers: _kJsonHeaders,
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final accessToken = data['access_token'] as String;
        final refreshToken = data['refresh_token'] as String?;
        final userId = data['user_id'] as String;
        final avatarUrl = data['avatar_url'] as String?;

        await _storeTokens(
          accessToken: accessToken,
          refreshToken: refreshToken ?? '',
          userId: userId,
          username: username,
        );

        await _setUserScope(userId);
        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: accessToken,
          refreshToken: refreshToken,
          avatarUrl: avatarUrl,
        );

        // Start background service to keep WebSocket alive on mobile
        BackgroundService.instance.start();
      } else {
        String errorMsg = 'Invalid username or password';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (e) {
          debugPrint('[Auth] login response parse failed: $e');
          errorMsg = 'Server error (${response.statusCode})';
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      final msg = e is TimeoutException
          ? 'Cannot reach server. Check your connection.'
          : e.toString().contains('FormatException')
          ? 'Cannot reach server. Check your connection.'
          : e.toString();
      state = state.copyWith(isLoading: false, error: msg);
    }
  }

  void updateAvatarUrl(String url) {
    state = state.copyWith(avatarUrl: url);
  }

  /// Set of presence status values accepted by the server. Keeping the
  /// client honest here avoids sending garbage that the server would just
  /// reject with a 400 -- and protects callers that build the string from
  /// user input or enum conversions.
  static const _validPresenceStatuses = <String>{
    'online',
    'away',
    'dnd',
    'invisible',
  };

  /// Update the user's presence status locally and on the server.
  Future<void> setPresenceStatus(String status) async {
    if (!_validPresenceStatuses.contains(status)) return;
    if (!state.isLoggedIn) return;
    // Optimistically update local state immediately.
    state = state.copyWith(presenceStatus: status);
    try {
      await authenticatedRequest(
        (token) => http.patch(
          Uri.parse('$_serverUrl/api/users/me/status'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'status': status}),
        ),
      );
    } catch (e) {
      debugPrint('[Auth] setPresenceStatus failed: $e');
    }
  }

  Future<void> logout() async {
    BackgroundService.instance.stop();
    SecureKeyStore.instance.clearUserScope();
    UserDataDir.instance.clearUser();
    await _clearStoredTokens();
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});
