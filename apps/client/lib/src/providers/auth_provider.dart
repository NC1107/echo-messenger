import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  const AuthState({
    this.isLoggedIn = false,
    this.userId,
    this.username,
    this.token,
    this.refreshToken,
    this.avatarUrl,
    this.error,
    this.isLoading = false,
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
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final Ref ref;

  AuthNotifier(this.ref) : super(const AuthState());

  static const _keyAccessToken = 'echo_auth_access_token';
  static const _keyRefreshToken = 'echo_auth_refresh_token';
  static const _keyUserId = 'echo_auth_user_id';
  static const _keyUsername = 'echo_auth_username';

  String get _serverUrl => ref.read(serverUrlProvider);

  /// Try to auto-login using stored refresh token from SharedPreferences.
  ///
  /// Loads the refresh token, calls the refresh endpoint to get a new access
  /// token, and restores the session. If the refresh fails (expired, revoked,
  /// or server unreachable), clears stored tokens and returns false so the
  /// user must log in manually.
  Future<bool> tryAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedRefreshToken = prefs.getString(_keyRefreshToken);
      final storedUserId = prefs.getString(_keyUserId);
      final storedUsername = prefs.getString(_keyUsername);

      if (storedRefreshToken == null || storedRefreshToken.isEmpty) {
        // No refresh token stored -- check for legacy access token as fallback
        final legacyToken = prefs.getString(_keyAccessToken);
        if (legacyToken != null &&
            legacyToken.isNotEmpty &&
            storedUserId != null &&
            storedUsername != null) {
          // Legacy mode: we have an access token but no refresh token.
          // Restore the session optimistically -- it may be expired, but
          // individual API calls will handle 401 gracefully.
          state = AuthState(
            isLoggedIn: true,
            userId: storedUserId,
            username: storedUsername,
            token: legacyToken,
          );
          return true;
        }

        // Also handle old-style stored password credentials by clearing them
        await _clearLegacyCredentials(prefs);
        return false;
      }

      // We have a refresh token -- attempt to get a new access token
      state = state.copyWith(isLoading: true);

      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/refresh'),
        headers: _kJsonHeaders,
        body: jsonEncode({'refresh_token': storedRefreshToken}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;
        final newRefreshToken =
            data['refresh_token'] as String? ?? storedRefreshToken;
        final userId = data['user_id'] as String? ?? storedUserId ?? '';
        final username = data['username'] as String? ?? storedUsername ?? '';

        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: newAccessToken,
          refreshToken: newRefreshToken,
        );

        await _storeTokens(
          accessToken: newAccessToken,
          refreshToken: newRefreshToken,
          userId: userId,
          username: username,
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
    final currentRefreshToken = state.refreshToken;
    if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
      // No refresh token available -- cannot refresh
      return false;
    }

    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/refresh'),
        headers: _kJsonHeaders,
        body: jsonEncode({'refresh_token': currentRefreshToken}),
      );

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
        logout();
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] refreshAccessToken failed: $e');
      // Network error -- don't logout, let caller handle
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
  Future<http.Response> authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    final token = state.token ?? '';
    final response = await requestFn(token);

    if (response.statusCode == 401) {
      // Attempt token refresh
      final refreshed = await refreshAccessToken();
      if (refreshed) {
        // Retry with new token
        return requestFn(state.token ?? '');
      }
      // Refresh failed -- logout already triggered by refreshAccessToken
    }

    return response;
  }

  /// Persist tokens to SharedPreferences.
  Future<void> _storeTokens({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String username,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccessToken, accessToken);
      await prefs.setString(_keyRefreshToken, refreshToken);
      await prefs.setString(_keyUserId, userId);
      await prefs.setString(_keyUsername, username);

      // Clean up legacy password key if it exists
      await _clearLegacyCredentials(prefs);
    } catch (_) {
      // Best effort
    }
  }

  /// Clear all stored tokens.
  Future<void> _clearStoredTokens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyAccessToken);
      await prefs.remove(_keyRefreshToken);
      await prefs.remove(_keyUserId);
      await prefs.remove(_keyUsername);
      await _clearLegacyCredentials(prefs);
    } catch (_) {
      // Best effort
    }
  }

  /// Remove legacy plaintext password storage from older versions.
  Future<void> _clearLegacyCredentials(SharedPreferences prefs) async {
    try {
      await prefs.remove('echo_auth_password');
    } catch (_) {
      // Best effort
    }
  }

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/register'),
        headers: _kJsonHeaders,
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final accessToken = data['access_token'] as String;
        // Server may or may not return refresh_token (backward compat)
        final refreshToken = data['refresh_token'] as String?;
        final userId = data['user_id'] as String;

        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: accessToken,
          refreshToken: refreshToken,
        );

        await _storeTokens(
          accessToken: accessToken,
          refreshToken: refreshToken ?? '',
          userId: userId,
          username: username,
        );
      } else {
        String errorMsg = 'Registration failed';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (_) {
          errorMsg = 'Server error (${response.statusCode})';
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      final msg = e.toString().contains('FormatException')
          ? 'Cannot reach server. Check your connection.'
          : e.toString();
      state = state.copyWith(isLoading: false, error: msg);
    }
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/login'),
        headers: _kJsonHeaders,
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final accessToken = data['access_token'] as String;
        final refreshToken = data['refresh_token'] as String?;
        final userId = data['user_id'] as String;
        final avatarUrl = data['avatar_url'] as String?;

        state = AuthState(
          isLoggedIn: true,
          userId: userId,
          username: username,
          token: accessToken,
          refreshToken: refreshToken,
          avatarUrl: avatarUrl,
        );

        await _storeTokens(
          accessToken: accessToken,
          refreshToken: refreshToken ?? '',
          userId: userId,
          username: username,
        );
      } else {
        String errorMsg = 'Invalid username or password';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (_) {
          errorMsg = 'Server error (${response.statusCode})';
        }
        state = state.copyWith(isLoading: false, error: errorMsg);
      }
    } catch (e) {
      final msg = e.toString().contains('FormatException')
          ? 'Cannot reach server. Check your connection.'
          : e.toString();
      state = state.copyWith(isLoading: false, error: msg);
    }
  }

  void updateAvatarUrl(String url) {
    state = state.copyWith(avatarUrl: url);
  }

  void logout() {
    _clearStoredTokens();
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});
