import 'package:flutter/material.dart';

/// Parse a `#RRGGBB` string into an opaque [Color], or return null when [hex]
/// is null, not exactly 7 chars, missing the leading `#`, or not valid hex.
///
/// Single source of truth so callers can't drift into an unvalidated
/// `int.parse(hex.substring(1))` that throws on a short or malformed value
/// (e.g. a backend that sends `#FFF` or `00FF00`). Callers that need a concrete
/// colour supply their own fallback: `parseHexColor(hex) ?? Colors.grey`.
Color? parseHexColor(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final value = int.tryParse(hex.substring(1), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// Lenient hex parse for hot paths (e.g. inside `CustomPainter.paint`): accepts
/// `RRGGBB` or `AARRGGBB`, with or without a leading `#`, and returns [fallback]
/// instead of null/throwing on anything malformed — so a stray colour string
/// from a future client or corruption can never throw mid-frame.
///
/// Use [parseHexColor] for validated, user-supplied input; use this only where
/// a concrete colour is required and per-call validation cost matters.
Color parseHexColorLenient(
  String hex, {
  Color fallback = const Color(0xFFFFFFFF),
}) {
  final s = hex.startsWith('#') ? hex.substring(1) : hex;
  if (s.length == 8) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return Color(v);
  } else if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return fallback;
}
