import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the custom voice-lounge background path.
const kVoiceLoungeBgPathKey = 'voice_lounge_bg_path';

/// SharedPreferences key for the optional custom vertex colour (32-bit ARGB).
const kVoiceLoungeVertexColorKey = 'voice_lounge_vertex_color';
const kVoiceLoungeVertexCountKey = 'voice_lounge_vertex_count';
const kVoiceLoungeConnectionDistanceKey = 'voice_lounge_connection_distance';

/// Defaults applied when the user hasn't customised the vertex-mesh.
/// Mirror `VertexMeshBackground`'s built-in defaults.
const int kDefaultVertexCount = 40;
const double kDefaultConnectionDistance = 120;

/// Immutable state for the voice-lounge background.
///
/// `customBackgroundPath` is `null` when the user hasn't picked a custom
/// background (the lounge falls back to the built-in vertex-mesh).  When set,
/// it points to a file on disk (typically copied into the app's document
/// directory so it survives reinstall-safe storage migrations).
///
/// `vertexColor`, `vertexCount`, `connectionDistance` tune the built-in
/// vertex-mesh when no custom image is in use. `null` on `vertexColor` means
/// "use the theme accent". Counts and distances persist across sessions.
@immutable
class VoiceLoungeBackgroundState {
  final String? customBackgroundPath;
  final Color? vertexColor;
  final int vertexCount;
  final double connectionDistance;

  const VoiceLoungeBackgroundState({
    this.customBackgroundPath,
    this.vertexColor,
    this.vertexCount = kDefaultVertexCount,
    this.connectionDistance = kDefaultConnectionDistance,
  });

  VoiceLoungeBackgroundState copyWith({
    Object? customBackgroundPath = _unset,
    Object? vertexColor = _unset,
    int? vertexCount,
    double? connectionDistance,
  }) {
    return VoiceLoungeBackgroundState(
      customBackgroundPath: identical(customBackgroundPath, _unset)
          ? this.customBackgroundPath
          : customBackgroundPath as String?,
      vertexColor: identical(vertexColor, _unset)
          ? this.vertexColor
          : vertexColor as Color?,
      vertexCount: vertexCount ?? this.vertexCount,
      connectionDistance: connectionDistance ?? this.connectionDistance,
    );
  }

  static const Object _unset = Object();
}

/// Provider for the voice-lounge background settings.
///
/// State is persisted to [SharedPreferences] under [kVoiceLoungeBgPathKey] so
/// the choice survives across launches.  Reads are guarded with an existence
/// check at render time — if the file is gone (manual delete, OS sandbox
/// migration), the lounge silently falls back to the default background.
final voiceLoungeBackgroundProvider =
    NotifierProvider<VoiceLoungeBackground, VoiceLoungeBackgroundState>(
      VoiceLoungeBackground.new,
    );

class VoiceLoungeBackground extends Notifier<VoiceLoungeBackgroundState> {
  @override
  VoiceLoungeBackgroundState build() {
    _load();
    return const VoiceLoungeBackgroundState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(kVoiceLoungeBgPathKey);
      final argb = prefs.getInt(kVoiceLoungeVertexColorKey);
      final count = prefs.getInt(kVoiceLoungeVertexCountKey);
      final dist = prefs.getDouble(kVoiceLoungeConnectionDistanceKey);
      state = state.copyWith(
        customBackgroundPath: (path != null && path.isNotEmpty) ? path : null,
        vertexColor: argb != null ? Color(argb) : null,
        vertexCount: count?.clamp(10, 120),
        connectionDistance: dist?.clamp(40.0, 240.0),
      );
    } catch (e) {
      debugPrint('[VoiceLoungeBackground] load failed: $e');
    }
  }

  /// Persists [path] as the custom background.  Pass `null` to clear and
  /// return to the default vertex-mesh background.
  Future<void> setCustomBackgroundPath(String? path) async {
    state = state.copyWith(customBackgroundPath: path);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (path == null || path.isEmpty) {
        await prefs.remove(kVoiceLoungeBgPathKey);
      } else {
        await prefs.setString(kVoiceLoungeBgPathKey, path);
      }
    } catch (e) {
      debugPrint('[VoiceLoungeBackground] persist failed: $e');
    }
  }

  Future<void> setVertexColor(Color? color) async {
    state = state.copyWith(vertexColor: color);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (color == null) {
        await prefs.remove(kVoiceLoungeVertexColorKey);
      } else {
        await prefs.setInt(kVoiceLoungeVertexColorKey, color.toARGB32());
      }
    } catch (e) {
      debugPrint('[VoiceLoungeBackground] persist vertexColor failed: $e');
    }
  }

  Future<void> setVertexCount(int count) async {
    final clamped = count.clamp(10, 120);
    state = state.copyWith(vertexCount: clamped);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kVoiceLoungeVertexCountKey, clamped);
    } catch (e) {
      debugPrint('[VoiceLoungeBackground] persist vertexCount failed: $e');
    }
  }

  Future<void> setConnectionDistance(double distance) async {
    final clamped = distance.clamp(40.0, 240.0);
    state = state.copyWith(connectionDistance: clamped);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(kVoiceLoungeConnectionDistanceKey, clamped);
    } catch (e) {
      debugPrint(
        '[VoiceLoungeBackground] persist connectionDistance failed: $e',
      );
    }
  }

  /// Clears the custom image background. Vertex tunables are preserved.
  Future<void> clear() => setCustomBackgroundPath(null);

  /// Resets every vertex tunable back to the defaults.
  Future<void> resetVertexDefaults() async {
    state = state.copyWith(
      vertexColor: null,
      vertexCount: kDefaultVertexCount,
      connectionDistance: kDefaultConnectionDistance,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kVoiceLoungeVertexColorKey);
      await prefs.remove(kVoiceLoungeVertexCountKey);
      await prefs.remove(kVoiceLoungeConnectionDistanceKey);
    } catch (e) {
      debugPrint('[VoiceLoungeBackground] resetVertexDefaults failed: $e');
    }
  }
}

/// Returns `true` when [path] is a non-empty filesystem path that points to
/// an existing file.  Web has no file:// concept here — the lounge treats
/// any web path as "missing" since [File] doesn't exist on the browser.
bool customBackgroundFileExists(String? path) {
  if (path == null || path.isEmpty) return false;
  if (kIsWeb) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}
