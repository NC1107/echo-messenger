import 'dart:js_interop';
import 'dart:math' as math;

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:web/web.dart' as web;

/// Web audio level analyzer using the Web Audio API AnalyserNode.
///
/// Connects the microphone MediaStream to an AnalyserNode and reads
/// frequency-domain data to compute a normalized volume level (0.0 - 1.0).
///
/// Follows the same pattern as livekit_client's _audio_analyser.dart.
class AudioLevelAnalyzer {
  web.AudioContext? _audioContext;
  web.AnalyserNode? _analyser;
  web.MediaStreamAudioSourceNode? _source;
  bool _disposed = false;

  AudioLevelAnalyzer.fromStream(webrtc.MediaStream stream) {
    try {
      _audioContext = web.AudioContext();
      _analyser = _audioContext!.createAnalyser();
      _analyser!.fftSize = 256;
      _analyser!.smoothingTimeConstant = 0.8;
      _analyser!.minDecibels = -100;
      _analyser!.maxDecibels = -80;

      // Cast to MediaStreamWeb to access the underlying browser MediaStream.
      // flutter_webrtc's web implementation returns MediaStreamWeb instances.
      final webStream = stream as MediaStreamWeb;
      _source = _audioContext!.createMediaStreamSource(webStream.jsStream);
      _source!.connect(_analyser!);
    } catch (_) {
      // Web Audio API not available -- getLevel() will return 0.0
    }
  }

  /// Returns a value between 0.0 and 1.0 representing current mic input level.
  double getLevel() {
    if (_disposed || _analyser == null) return 0.0;

    try {
      final dataArray = JSUint8Array.withLength(_analyser!.frequencyBinCount);
      _analyser!.getByteFrequencyData(dataArray);

      // Compute RMS from frequency data (same algorithm as livekit_client)
      final data = dataArray.toDart;
      if (data.isEmpty) return 0.0;

      num sum = 0;
      for (final amplitude in data) {
        sum += math.pow(amplitude / 255, 2);
      }
      return math.sqrt(sum / data.length);
    } catch (_) {
      return 0.0;
    }
  }

  void dispose() {
    _disposed = true;
    try {
      _source?.disconnect();
      _audioContext?.close();
    } catch (_) {}
    _source = null;
    _analyser = null;
    _audioContext = null;
  }
}
