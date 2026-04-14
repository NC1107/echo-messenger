import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:livekit_client/livekit_client.dart' as lk;

/// Returns a CSS hex color string (e.g. `#FF5500`) for the given [Color].
String colorToHex(Color color) {
  final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#$r$g$b';
}

final _idRng = math.Random.secure();

/// Generate a 128-bit random hex id (16 bytes).
///
/// Used for stroke IDs and image IDs on the canvas to ensure collision
/// resistance consistent with the rest of the codebase.
String newCanvasId() {
  final bytes = List<int>.generate(16, (_) => _idRng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Resolve a LiveKit participant's display name, preferring name > identity > sid.
String participantDisplayName(lk.Participant participant) {
  if (participant.name.isNotEmpty) return participant.name;
  if (participant.identity.isNotEmpty) return participant.identity;
  return participant.sid.toString();
}
