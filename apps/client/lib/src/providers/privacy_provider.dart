import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

class PrivacyState {
  final bool readReceiptsEnabled;
  final bool emailVisible;
  final bool phoneVisible;
  final bool emailDiscoverable;
  final bool phoneDiscoverable;
  final bool isLoading;
  final String? error;

  const PrivacyState({
    this.readReceiptsEnabled = true,
    this.emailVisible = false,
    this.phoneVisible = false,
    this.emailDiscoverable = false,
    this.phoneDiscoverable = false,
    this.isLoading = false,
    this.error,
  });

  PrivacyState copyWith({
    bool? readReceiptsEnabled,
    bool? emailVisible,
    bool? phoneVisible,
    bool? emailDiscoverable,
    bool? phoneDiscoverable,
    bool? isLoading,
    String? error,
  }) {
    return PrivacyState(
      readReceiptsEnabled: readReceiptsEnabled ?? this.readReceiptsEnabled,
      emailVisible: emailVisible ?? this.emailVisible,
      phoneVisible: phoneVisible ?? this.phoneVisible,
      emailDiscoverable: emailDiscoverable ?? this.emailDiscoverable,
      phoneDiscoverable: phoneDiscoverable ?? this.phoneDiscoverable,
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
          emailVisible: data['email_visible'] as bool? ?? false,
          phoneVisible: data['phone_visible'] as bool? ?? false,
          emailDiscoverable: data['email_discoverable'] as bool? ?? false,
          phoneDiscoverable: data['phone_discoverable'] as bool? ?? false,
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
    bool? emailVisible,
    bool? phoneVisible,
    bool? emailDiscoverable,
    bool? phoneDiscoverable,
  }) async {
    final prev = state;
    state = state.copyWith(
      readReceiptsEnabled: readReceiptsEnabled ?? state.readReceiptsEnabled,
      emailVisible: emailVisible ?? state.emailVisible,
      phoneVisible: phoneVisible ?? state.phoneVisible,
      emailDiscoverable: emailDiscoverable ?? state.emailDiscoverable,
      phoneDiscoverable: phoneDiscoverable ?? state.phoneDiscoverable,
      isLoading: true,
      error: null,
    );

    try {
      final response = await _authenticatedRequest(
        (token) => http.patch(
          Uri.parse('$_serverUrl/api/users/me/privacy'),
          headers: _headersWithToken(token),
          body: jsonEncode({
            // ignore: use_null_aware_elements
            if (readReceiptsEnabled != null)
              'read_receipts_enabled': readReceiptsEnabled,
            // ignore: use_null_aware_elements
            if (emailVisible != null) 'email_visible': emailVisible,
            // ignore: use_null_aware_elements
            if (phoneVisible != null) 'phone_visible': phoneVisible,
            // ignore: use_null_aware_elements
            if (emailDiscoverable != null)
              'email_discoverable': emailDiscoverable,
            // ignore: use_null_aware_elements
            if (phoneDiscoverable != null)
              'phone_discoverable': phoneDiscoverable,
          }),
        ),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          readReceiptsEnabled: data['read_receipts_enabled'] as bool? ?? true,
          emailVisible: data['email_visible'] as bool? ?? false,
          phoneVisible: data['phone_visible'] as bool? ?? false,
          emailDiscoverable: data['email_discoverable'] as bool? ?? false,
          phoneDiscoverable: data['phone_discoverable'] as bool? ?? false,
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

  Future<void> setEmailVisible(bool value) async {
    await _patch(emailVisible: value);
  }

  Future<void> setPhoneVisible(bool value) async {
    await _patch(phoneVisible: value);
  }

  Future<void> setEmailDiscoverable(bool value) async {
    await _patch(emailDiscoverable: value);
  }

  Future<void> setPhoneDiscoverable(bool value) async {
    await _patch(phoneDiscoverable: value);
  }
}

final privacyProvider = StateNotifierProvider<PrivacyNotifier, PrivacyState>((
  ref,
) {
  return PrivacyNotifier(ref);
});
