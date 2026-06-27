import 'dart:async';
import 'dart:io';

/// Map technical exceptions to short, user-facing strings.
///
/// Prefer this over surfacing raw `e.toString()` in toasts and banners --
/// users should not see stack-trace fragments, hostnames, or status codes.
String friendlyError(Object e) {
  if (e is SocketException) {
    return "Can't reach Echo. Check your internet connection.";
  }
  if (e is TimeoutException) {
    return 'Echo is taking too long to respond. Try again.';
  }
  if (e is FormatException) {
    return 'The server returned an unexpected response.';
  }
  final s = e.toString();
  if (s.contains('413')) return 'That file is too large.';
  if (s.contains('429')) return 'Too many requests. Slow down.';
  if (RegExp(r'\b5\d\d\b').hasMatch(s)) {
    return 'Echo is temporarily unavailable. Try again in a moment.';
  }
  return 'Something went wrong. Try again.';
}

/// Specialized variant for the login screen. The generic [friendlyError]
/// fallback ("Something went wrong. Try again.") leaves the user with no
/// signal about *why* the sign-in failed — wrong credentials, server down,
/// or the laptop being offline all read identically. This variant returns:
///
/// - 401 / 403  → "Invalid username or password." (the credential path)
/// - 404 / 405  → "This server isn't responding as an Echo server…" — the
///   endpoint isn't there, which almost always means the configured server URL
///   points at the wrong host (e.g. a static/marketing site). Surfacing this as
///   a credential error sent testers chasing the wrong problem (#1063 fallout).
/// - SocketException / TimeoutException → "Can't reach the server. Check
///   your connection or server URL."
/// - 5xx → "Server error — please try again in a moment."
/// - Anything else → falls back to [friendlyError].
///
/// Pass [statusCode] when you have one (the HTTP layer parsed a non-2xx
/// response); pass [exception] when the request blew up before getting a
/// response. Exactly one is expected.
String friendlyLoginError({int? statusCode, Object? exception}) {
  if (statusCode != null) {
    if (statusCode == 401 || statusCode == 403) {
      return 'Invalid username or password.';
    }
    if (statusCode == 404 || statusCode == 405) {
      return "This server isn't responding as an Echo server. "
          'Check the server URL.';
    }
    if (statusCode >= 500 && statusCode < 600) {
      return 'Server error — please try again in a moment.';
    }
  }
  if (exception is SocketException || exception is TimeoutException) {
    return "Can't reach the server. Check your connection or server URL.";
  }
  if (exception != null) return friendlyError(exception);
  return 'Invalid username or password.';
}
