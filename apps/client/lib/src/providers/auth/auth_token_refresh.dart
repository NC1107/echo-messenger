part of 'auth_provider.dart';

/// Refresh-token flow for the auth notifier — covers cold-start auto-login,
/// the in-flight-coalesced [refreshAccessToken] entrypoint, the platform-
/// specific call shapes (web cookie vs native body), and the 401-retry
/// wrapper [authenticatedRequest] that every other authenticated call
/// in the app routes through.
///
/// Mixed in alongside [AuthTokenStorageMixin]; the `on` clause makes the
/// storage helpers (`_storeTokens` / `_clearStoredTokens` / `_setUserScope`
/// / `migrateTokensFromSharedPreferences`) statically visible from here.
mixin AuthTokenRefreshMixin on Notifier<AuthState>, AuthTokenStorageMixin {
  /// Lock to prevent concurrent token refresh calls. When a refresh is
  /// in-flight, subsequent callers await the same Future instead of
  /// sending duplicate refresh requests (which would fail due to
  /// server-side token rotation consuming the token on first use).
  Completer<bool>? _refreshLock;

  /// `logout` is provided by [AuthNotifier]; refresh-failure paths call
  /// it so the user is redirected back to the login screen on a stale
  /// or revoked token.
  Future<void> logout({String? serverUrl});

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
  /// successful cookie-based refresh. If neither is present the user must log in.
  ///
  /// If the refresh fails (expired, revoked, or server unreachable), clears
  /// stored tokens and returns false so the user must log in manually.
  Future<bool> tryAutoLogin() async {
    try {
      // Migrate tokens from SharedPreferences to secure storage if needed.
      await migrateTokensFromSharedPreferences();

      final prefs = await SharedPreferences.getInstance();
      final storedUserId = prefs.getString(AuthNotifier._keyUserId);
      final storedUsername = prefs.getString(AuthNotifier._keyUsername);

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
          AuthNotifier._keyRefreshToken,
        );
      } catch (_) {
        // Secure storage unavailable -- fall through to prefs.
      }
      storedRefreshToken ??= prefs.getString(AuthNotifier._keyRefreshToken);

      if (storedRefreshToken == null || storedRefreshToken.isEmpty) {
        // No refresh token stored -- check for legacy access token as fallback
        String? legacyToken;
        try {
          legacyToken = await SecureKeyStore.instance.readGlobal(
            AuthNotifier._keyAccessToken,
          );
        } catch (_) {}
        legacyToken ??= prefs.getString(AuthNotifier._keyAccessToken);
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
              // Empty `{}` body, not no body: with `Content-Type:
              // application/json` set, axum's `Option<Json<T>>` extractor
              // tries to parse and fails with "EOF" on a zero-length body,
              // which short-circuits before the cookie path runs and the
              // user gets logged out on every refresh.  An empty object is
              // valid JSON and makes serde's #[serde(default)] kick in.
              body: '{}',
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
        // Let the browser attach the cookie automatically.  Send an empty
        // `{}` body rather than nothing -- axum's Option<Json<T>> extractor
        // fails with "EOF" if Content-Type is application/json and the body
        // is zero-length, which short-circuits before the cookie path can
        // run.  See companion comment in tryAutoLogin's _tryRefreshWithCookie.
        final client = buildHttpClient();
        try {
          response = await client
              .post(
                Uri.parse('$_serverUrl/api/auth/refresh'),
                headers: _kJsonHeaders,
                body: '{}',
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
