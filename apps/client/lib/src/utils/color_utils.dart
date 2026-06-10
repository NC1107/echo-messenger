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
