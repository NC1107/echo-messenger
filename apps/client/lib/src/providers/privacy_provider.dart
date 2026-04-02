import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

class PrivacyState {
  final bool readReceiptsEnabled;
  final bool allowUnencryptedDm;
  final bool isLoading;
  final String? error;

  const PrivacyState({
    this.readReceiptsEnabled = true,
    this.allowUnencryptedDm = true,
    this.isLoading = false,
    this.error,
  });

  PrivacyState copyWith({
    bool? readReceiptsEnabled,
    bool? allowUnencryptedDm,
    bool? isLoading,
    String? error,
  }) {
    return PrivacyState(
      readReceiptsEnabled: readReceiptsEnabled ?? this.readReceiptsEnabled,
      allowUnencryptedDm: allowUnencryptedDm ?? this.allowUnencryptedDm,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class PrivacyNotifier extends StateNotifier<PrivacyState> {
  final Ref ref;

  PrivacyNotifier(this.ref) : super(const PrivacyState());

  String get _serverUrl => ref.read(serverUrlProvider);

  Map<String, String> _headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    return ref.read(authProvider.notifier).authenticatedRequest(requestFn);
  }

  Future<void> load() async {
    if (!ref.read(authProvider).isLoggedIn) {
      state = const PrivacyState();
      return;
    }

    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/users/me/privacy'),
          headers: _headersWithToken(token),
        ),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          readReceiptsEnabled: data['read_receipts_enabled'] as bool? ?? true,
          allowUnencryptedDm:
              data['allow_unencrypted_dm'] as bool? ?? true,
          isLoading: false,
          error: null,
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load privacy settings',
        );
      }
    } catch (e) {
      debugPrint('[Privacy] load failed: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> _patch({
    bool? readReceiptsEnabled,
    bool? allowUnencryptedDm,
  }) async {
    final prev = state;
    state = state.copyWith(
      readReceiptsEnabled: readReceiptsEnabled ?? state.readReceiptsEnabled,
      allowUnencryptedDm: allowUnencryptedDm ?? state.allowUnencryptedDm,
      isLoading: true,
      error: null,
    );

    try {
      final response = await _authenticatedRequest(
        (token) => http.patch(
          Uri.parse('$_serverUrl/api/users/me/privacy'),
          headers: _headersWithToken(token),
          body: jsonEncode({
            if (readReceiptsEnabled != null)
              'read_receipts_enabled': readReceiptsEnabled,
            if (allowUnencryptedDm != null)
              'allow_unencrypted_dm': allowUnencryptedDm,
          }),
        ),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          readReceiptsEnabled: data['read_receipts_enabled'] as bool? ?? true,
          allowUnencryptedDm:
              data['allow_unencrypted_dm'] as bool? ?? true,
          isLoading: false,
          error: null,
        );
      } else {
        state = prev.copyWith(
          isLoading: false,
          error: 'Failed to save privacy settings',
        );
      }
    } catch (e) {
      debugPrint('[Privacy] update failed: $e');
      state = prev.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> setReadReceiptsEnabled(bool value) async {
    await _patch(readReceiptsEnabled: value);
  }

  Future<void> setAllowUnencryptedDm(bool value) async {
    await _patch(allowUnencryptedDm: value);
  }
}

final privacyProvider = StateNotifierProvider<PrivacyNotifier, PrivacyState>((
  ref,
) {
  return PrivacyNotifier(ref);
});
