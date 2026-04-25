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
