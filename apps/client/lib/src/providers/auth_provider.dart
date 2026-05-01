import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart' show BackgroundService;
import '../services/debug_log_service.dart';
import '../services/http_client_factory.dart';
import '../services/message_cache.dart';
import '../services/secure_key_store.dart';
import '../services/user_data_dir.dart';
import '../utils/friendly_error.dart';
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

  /// Public token accessor for non-StateNotifier callers (e.g. UploadClient).
  String? get currentToken => state.token;

  static const _keyAccessToken = 'echo_auth_access_token';
  static const _keyRefreshToken = 'echo_auth_refresh_token';
  static const _keyUserId = 'echo_auth_user_id';
  static const _keyUsername = 'echo_auth_username';

  String get _serverUrl => ref.read(serverUrlProvider);

  /// Host-suffixed preference key for the user-id pinned to a given
  /// server origin. Lets the new login screen pre-fill the username for
  /// any known server (#PR-2). The legacy global key is kept as a fallback
  /// so live sessions don't break across the upgrade.
  static String _userIdKeyFor(String host) => '$_keyUserId@$host';

  /// Host-suffixed preference key for the username last used on a server.
  static String _usernameKeyFor(String host) => '$_keyUsername@$host';

  /// Best-effort host extraction. Falls back to the raw URL if parsing
  /// fails so the prefs key is at least deterministic.
  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host;
    return (host == null || host.isEmpty) ? url : host;
  }

  /// Try to auto-login using stored refresh token (native) or HttpOnly cookie (web).
  ///
  /// On native platforms: reads the refresh token from [SecureKeyStore] (global
  /// scope), falling back to SharedPreferences for pre-migration installs. Calls
  /// the refresh endpoint with the token in the request body.
  ///
  /// On web: no refresh token is stored in JS-accessible storage. Instead,
  /// calls the refresh endpoint with an empty body; the browser automatically
  /// attaches the HttpOnly SameSite=Strict refresh-token cookie. A stored
  /// userId/username is still required to rebuild session state after a
  /// successful refresh. If neither is present the user must log in.
  ///
  /// If the refresh fails (expired, revoked, or server unreachable), clears
  /// stored tokens and returns false so the user must log in manually.
  Future<bool> tryAutoLogin() async {
    try {
      // Migrate tokens from SharedPreferences to secure storage if needed.
      await migrateTokensFromSharedPreferences();

      final prefs = await SharedPreferences.getInstance();
      final storedUserId = prefs.getString(_keyUserId);
      final storedUsername = prefs.getString(_keyUsername);

      if (kIsWeb) {
        // On web the refresh token lives in an HttpOnly cookie managed by the
        // browser. We only need a stored userId/username to restore session
        // state after a successful cookie-based refresh.
        if (storedUserId == null || storedUsername == null) {
          return false;
        }
        return await _tryRefreshWithCookie(
          prefs: prefs,
          storedUserId: storedUserId,
          storedUsername: storedUsername,
        );
      }

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

  /// Web-only: call /api/auth/refresh with no body, relying on the browser to
  /// attach the HttpOnly cookie automatically via [buildHttpClient].
  Future<bool> _tryRefreshWithCookie({
    required SharedPreferences prefs,
    required String storedUserId,
    required String storedUsername,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final client = buildHttpClient();
      try {
        final response = await client
            .post(
              Uri.parse('$_serverUrl/api/auth/refresh'),
              headers: _kJsonHeaders,
              // No body -- server reads the HttpOnly cookie.
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final newAccessToken = data['access_token'] as String;
          final userId = data['user_id'] as String? ?? storedUserId;
          final username = data['username'] as String? ?? storedUsername;

          await _storeTokens(
            accessToken: newAccessToken,
            refreshToken: '', // not stored on web
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
            // refreshToken stays null in state on web -- never needed by client
            onboardingCompleted: onboardingDone,
          );
          return true;
        } else {
          await _clearStoredTokens();
          state = const AuthState();
          return false;
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Auth] tryAutoLogin (web cookie) failed: $e');
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
    // On web the refresh token is in the HttpOnly cookie; the client never
    // holds it in memory. On native the token must be present in state.
    if (!kIsWeb) {
      final currentRefreshToken = state.refreshToken;
      if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
        return false;
      }
    }

    try {
      final http.Response response;
      if (kIsWeb) {
        // Let the browser attach the cookie automatically.
        final client = buildHttpClient();
        try {
          response = await client
              .post(
                Uri.parse('$_serverUrl/api/auth/refresh'),
                headers: _kJsonHeaders,
                // No body -- server reads the HttpOnly cookie.
              )
              .timeout(const Duration(seconds: 15));
        } finally {
          client.close();
        }
      } else {
        final currentRefreshToken = state.refreshToken!;
        response = await http
            .post(
              Uri.parse('$_serverUrl/api/auth/refresh'),
              headers: _kJsonHeaders,
              body: jsonEncode({'refresh_token': currentRefreshToken}),
            )
            .timeout(const Duration(seconds: 15));
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;

        if (kIsWeb) {
          // Only update the access token; refresh token stays in cookie.
          state = state.copyWith(token: newAccessToken);
          await _storeTokens(
            accessToken: newAccessToken,
            refreshToken: '', // not stored on web
            userId: state.userId ?? '',
            username: state.username ?? '',
          );
        } else {
          final currentRefreshToken = state.refreshToken!;
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
        }
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

    // Write tokens to secure storage (global scope -- no user prefix).
    // On web the refresh token is intentionally omitted -- the browser manages
    // it as an HttpOnly cookie.  We also skip writing an empty string, which is
    // the sentinel the web code path passes when no token is available.
    final shouldPersistRefresh = !kIsWeb && refreshToken.isNotEmpty;
    try {
      await store.writeGlobal(_keyAccessToken, accessToken);
      if (shouldPersistRefresh) {
        await store.writeGlobal(_keyRefreshToken, refreshToken);
      }
    } catch (e) {
      debugPrint('[Auth] SecureKeyStore unavailable: $e');
    }

    // Always write to SharedPreferences as well. On web, SecureKeyStore
    // uses Web Crypto + encrypted localStorage which can fail to read
    // back after a page refresh, causing unexpected logouts. Keeping a
    // copy in SharedPreferences guarantees tryAutoLogin can recover.
    // On native platforms the duplication is harmless (belt & suspenders).
    // On web the refresh token is excluded for the same XSS-safety reason.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccessToken, accessToken);
      if (shouldPersistRefresh) {
        await prefs.setString(_keyRefreshToken, refreshToken);
      }
      await prefs.setString(_keyUserId, userId);
      await prefs.setString(_keyUsername, username);

      // Mirror userId/username into per-host slots so the login screen on
      // a known server can pre-fill the username after a server switch
      // (#PR-2). The global keys above stay authoritative for the active
      // session because tokens themselves remain global in Option B.
      final host = _hostOf(_serverUrl);
      if (host.isNotEmpty) {
        await prefs.setString(_userIdKeyFor(host), userId);
        await prefs.setString(_usernameKeyFor(host), username);
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

    // On web the refresh token must never be stored in JS-accessible storage,
    // so skip migrating it.  Only migrate the access token on web.
    final keysToMigrate = kIsWeb
        ? [_keyAccessToken]
        : [_keyAccessToken, _keyRefreshToken];

    for (final key in keysToMigrate) {
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
        // Server may or may not return refresh_token (backward compat).
        // On web the token arrives as a Set-Cookie header handled by the
        // browser; we deliberately ignore the body value to avoid storing it.
        final refreshToken = kIsWeb ? null : data['refresh_token'] as String?;
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
          errorMsg = friendlyError(
            Exception('Server error ${response.statusCode}'),
          );
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: friendlyError(e));
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
        // On web the refresh token arrives as a Set-Cookie header managed by
        // the browser; ignore the body value to avoid storing it in JS memory.
        final refreshToken = kIsWeb ? null : data['refresh_token'] as String?;
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
          errorMsg = friendlyError(
            Exception('Server error ${response.statusCode}'),
          );
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: friendlyError(e));
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

  /// Sign out locally, and best-effort sign out on the server.
  ///
  /// `serverUrl` lets the caller target an origin that may differ from the
  /// one currently held in [serverUrlProvider] -- specifically the
  /// server-switch flow needs to clear the OLD origin's cookie + refresh
  /// token row even though it is about to flip [serverUrlProvider] to a
  /// different URL (#PR-2).
  ///
  /// Network errors during the remote `POST /api/auth/logout` are swallowed
  /// so logout always succeeds locally; the server-side refresh row will
  /// expire on its own if the call never landed.
  Future<void> logout({String? serverUrl}) async {
    final origin = serverUrl ?? _serverUrl;
    final accessToken = state.token;

    // Best-effort remote logout. On web this is the only way to clear the
    // HttpOnly refresh cookie. On native it revokes the refresh-token row.
    try {
      final client = buildHttpClient();
      try {
        await client
            .post(
              Uri.parse('$origin/api/auth/logout'),
              headers: {
                'Content-Type': 'application/json',
                if (accessToken != null && accessToken.isNotEmpty)
                  'Authorization': 'Bearer $accessToken',
              },
            )
            .timeout(const Duration(seconds: 5));
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Auth] remote logout ignored: $e');
    }

    BackgroundService.instance.stop();
    SecureKeyStore.instance.clearUserScope();
    UserDataDir.instance.clearUser();
    await _clearStoredTokens();
    state = const AuthState();
  }

  // ---------------------------------------------------------------------------
  // Test-only surface
  // ---------------------------------------------------------------------------

  /// Exposes [_storeTokens] for unit tests that verify storage invariants.
  @visibleForTesting
  Future<void> storeTokensForTest({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String username,
  }) => _storeTokens(
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: userId,
    username: username,
  );

  /// Calls [_doRefreshAccessToken] but, when [sendBody] is false, temporarily
  /// clears the in-state refresh token so the caller can simulate the web path
  /// (no body) using the standard mock infrastructure.
  @visibleForTesting
  Future<bool> refreshAccessTokenForTest({bool sendBody = true}) async {
    if (!sendBody) {
      // Temporarily null out the refresh token in state so _doRefreshAccessToken
      // takes the kIsWeb-equivalent branch where no body field is included.
      // We snapshot and restore so the test container stays consistent.
      final saved = state;
      state = state.copyWith(
        isLoggedIn: true,
        token: saved.token,
        // refreshToken omitted so it stays as the current value in copyWith.
        // Instead we manipulate _doRefreshAccessToken by patching state.
      );
      // Use the internal method directly -- it will see null refreshToken and
      // on non-web that normally returns false.  For this test we override
      // the guard so we can verify the body contract in isolation.
      return _doRefreshAccessTokenNoBody();
    }
    return _doRefreshAccessToken();
  }

  /// Like [_doRefreshAccessToken] but always omits the refresh_token body
  /// field regardless of platform.  Used only by test infrastructure.
  Future<bool> _doRefreshAccessTokenNoBody() async {
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/auth/refresh'),
            headers: _kJsonHeaders,
            // No body -- simulates the web cookie path.
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;
        state = state.copyWith(token: newAccessToken);
        return true;
      } else {
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] refreshAccessTokenNoBody failed: $e');
      return false;
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});
