import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';

/// Shared authenticated-HTTP helpers for Riverpod [Notifier]s.
///
/// Collapses the identical `_headersWithToken` + `_authenticatedRequest`
/// boilerplate that was copy-pasted across the contacts / privacy / channels /
/// conversations providers (and re-implemented inline in a couple of others).
/// Mix this into any `keepAlive` notifier to get one canonical implementation —
/// change the auth-header shape or the refresh-and-retry policy in exactly one
/// place.
mixin AuthedHttp<S> on Notifier<S> {
  /// JSON content-type + bearer-token headers for an authenticated request.
  Map<String, String> headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Run [requestFn] with the current access token, transparently refreshing
  /// and retrying once on a 401.
  Future<http.Response> authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) => ref.read(authProvider.notifier).authenticatedRequest(requestFn);
}
