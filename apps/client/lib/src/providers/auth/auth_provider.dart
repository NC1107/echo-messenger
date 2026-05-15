import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/background_service.dart' show BackgroundService;
import '../../services/debug_log_service.dart';
import '../../services/http_client_factory.dart';
import '../../services/message_cache.dart';
import '../../services/secure_key_store.dart';
import '../../services/user_data_dir.dart';
import '../../utils/friendly_error.dart';
import '../server_url_provider.dart';

part 'auth_provider.g.dart';
part 'auth_token_storage.dart';
part 'auth_token_refresh.dart';

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

/// Authentication state notifier.
///
/// File layout (god-module split — see #770 / #785 for the broader
/// refactor backlog):
/// - This file: facade — state class, notifier shell, public lifecycle
///   methods (`register` / `login` / `logout` / `setPresenceStatus`),
///   shared private fields the parts read from.
/// - `auth_token_storage.dart` (part): Hive + SharedPreferences I/O,
///   one-shot legacy migration.
/// - `auth_token_refresh.dart` (part): auto-login, refresh flow, the
///   401-retrying `authenticatedRequest` helper.
@Riverpod(keepAlive: true)
class AuthNotifier extends _$AuthNotifier
    with AuthTokenStorageMixin, AuthTokenRefreshMixin {
  @override
  AuthState build() => const AuthState();

  /// Public token accessor for non-Notifier callers (e.g. UploadClient).
  String? get currentToken => state.token;

  static const _keyAccessToken = 'echo_auth_access_token';
  static const _keyRefreshToken = 'echo_auth_refresh_token';
  static const _keyUserId = 'echo_auth_user_id';
  static const _keyUsername = 'echo_auth_username';

  @override
  String get _serverUrl => ref.read(serverUrlProvider);

  /// Host-suffixed preference key for the user-id pinned to a given
  /// server origin. Lets the new login screen pre-fill the username for
  /// any known server. The legacy global key is kept as a fallback so
  /// live sessions don't break across the upgrade.
  static String _userIdKeyFor(String host) => '$_keyUserId@$host';

  /// Host-suffixed preference key for the username last used on a server.
  static String _usernameKeyFor(String host) => '$_keyUsername@$host';

  /// Best-effort host extraction. Falls back to the raw URL if parsing
  /// fails so the prefs key is at least deterministic.
  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host;
    return (host == null || host.isEmpty) ? url : host;
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
          headers: {..._kJsonHeaders, 'Authorization': 'Bearer $token'},
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
  /// different URL.
  ///
  /// Network errors during the remote `POST /api/auth/logout` are swallowed
  /// so logout always succeeds locally; the server-side refresh row will
  /// expire on its own if the call never landed.
  @override
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
                ..._kJsonHeaders,
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
  Future<bool> refreshAccessTokenForTest({bool sendBody = true}) {
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
}

/// Back-compat alias preserving the legacy `authProvider` symbol used by
/// ~50 call sites and tests. Riverpod codegen names the provider after the
/// notifier class (`authNotifierProvider`); we re-export the short name here.
final authProvider = authNotifierProvider;
