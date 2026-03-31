import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthState {
  final bool isLoggedIn;
  final String? userId;
  final String? username;
  final String? token;
  final String? error;
  final bool isLoading;

  const AuthState({
    this.isLoggedIn = false,
    this.userId,
    this.username,
    this.token,
    this.error,
    this.isLoading = false,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    String? userId,
    String? username,
    String? token,
    String? error,
    bool? isLoading,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      token: token ?? this.token,
      error: error,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState());

  static const _keyUsername = 'echo_auth_username';
  static const _keyPassword = 'echo_auth_password';

  String _serverUrl = 'http://localhost:8080';

  void setServerUrl(String url) => _serverUrl = url;

  /// Try to auto-login using stored credentials from SharedPreferences.
  Future<bool> tryAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString(_keyUsername);
      final password = prefs.getString(_keyPassword);
      if (username != null && password != null) {
        await login(username, password);
        return state.isLoggedIn;
      }
    } catch (_) {
      // Auto-login failed silently -- user can log in manually
    }
    return false;
  }

  /// Persist credentials to SharedPreferences for auto-login on restart.
  Future<void> _storeCredentials(String username, String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUsername, username);
      await prefs.setString(_keyPassword, password);
    } catch (_) {
      // Best effort
    }
  }

  /// Clear stored credentials.
  Future<void> _clearCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyUsername);
      await prefs.remove(_keyPassword);
    } catch (_) {
      // Best effort
    }
  }

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = AuthState(
          isLoggedIn: true,
          userId: data['user_id'] as String,
          username: username,
          token: data['access_token'] as String,
        );
        await _storeCredentials(username, password);
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          isLoading: false,
          error: data['error'] as String? ?? 'Registration failed',
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = AuthState(
          isLoggedIn: true,
          userId: data['user_id'] as String,
          username: username,
          token: data['access_token'] as String,
        );
        await _storeCredentials(username, password);
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          isLoading: false,
          error: data['error'] as String? ?? 'Login failed',
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void logout() {
    _clearCredentials();
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
