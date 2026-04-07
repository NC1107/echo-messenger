import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// Stub (non-web) audio level analyzer.
///
/// On desktop, flutter_webrtc does not expose the Web Audio API, so we
/// fall back to a basic approach using getStats on the media stream.
/// For now this returns a rough approximation until native audio metering
/// is integrated.
class AudioLevelAnalyzer {
  bool _disposed = false;

  // ignore: unused_field
  final webrtc.MediaStream _stream;

  AudioLevelAnalyzer.fromStream(webrtc.MediaStream stream) : _stream = stream;
  // Desktop: no Web Audio API available.
  // The caller should poll getLevel() on a timer.

  /// Returns a value between 0.0 and 1.0 representing current mic input level.
  /// On desktop without native metering, returns 0.0 (level bar stays empty).
  double getLevel() {
    if (_disposed) return 0.0;
    return 0.0;
  }

  void dispose() {
    _disposed = true;
  }
}
