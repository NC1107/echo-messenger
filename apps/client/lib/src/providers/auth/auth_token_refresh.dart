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
  Future<void> logout({String? serverUrl, bool forgetAccount});

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
        // Web: refresh token is in HttpOnly cookie; just need stored user info.
        if (storedUserId == null || storedUsername == null) {
          return false;
        }
        return await _tryRefreshWithCookie(
          prefs: prefs,
          storedUserId: storedUserId,
          storedUsername: storedUsername,
        );
      }

      // Prefer secure storage; fall back to prefs if storage was unavailable.
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
          // Legacy: optimistic restore from access token; 401 path handles expiry.
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
        // (#1160) Server re-reads is_admin on refresh so promotion propagates;
        // without parsing it native cold-restart hides the admin panel.
        final isAdmin = data['is_admin'] as bool? ?? false;

        // Persist tokens FIRST: server already revoked the old one in rotation,
        // so a downstream throw must not lose the new token.
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
          isAdmin: isAdmin,
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
      // Network failure: don't clear tokens — let user retry when online.
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
              // '{}' (not empty): axum's Option<Json<T>> fails on zero-length
              // body with Content-Type: application/json, bypassing the cookie path.
              body: '{}',
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final newAccessToken = data['access_token'] as String;
          final userId = data['user_id'] as String? ?? storedUserId;
          final username = data['username'] as String? ?? storedUsername;
          // (#1160) Parse is_admin so promotion propagates on web too.
          final isAdmin = data['is_admin'] as bool? ?? false;

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
            isAdmin: isAdmin,
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
    // Coalesce in-flight refresh: server rotation consumes on first use.
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
    // Web: token is in HttpOnly cookie. Native: must be in state.
    if (!kIsWeb) {
      final currentRefreshToken = state.refreshToken;
      if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
        return false;
      }
    }

    try {
      final http.Response response;
      if (kIsWeb) {
        // Browser attaches cookie; '{}' body avoids axum EOF on Option<Json<T>>.
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
