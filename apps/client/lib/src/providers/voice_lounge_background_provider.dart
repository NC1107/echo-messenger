import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the custom voice-lounge background path.
const kVoiceLoungeBgPathKey = 'voice_lounge_bg_path';

/// Immutable state for the voice-lounge background.
///
/// `customBackgroundPath` is `null` when the user hasn't picked a custom
/// background (the lounge falls back to the built-in vertex-mesh).  When set,
/// it points to a file on disk (typically copied into the app's document
/// directory so it survives reinstall-safe storage migrations).
@immutable
class VoiceLoungeBackgroundState {
  final String? customBackgroundPath;

  const VoiceLoungeBackgroundState({this.customBackgroundPath});

  VoiceLoungeBackgroundState copyWith({Object? customBackgroundPath = _unset}) {
    return VoiceLoungeBackgroundState(
      customBackgroundPath: identical(customBackgroundPath, _unset)
          ? this.customBackgroundPath
          : customBackgroundPath as String?,
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
      if (path != null && path.isNotEmpty) {
        state = state.copyWith(customBackgroundPath: path);
      }
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

  /// Convenience: clear the custom background.
  Future<void> clear() => setCustomBackgroundPath(null);
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
