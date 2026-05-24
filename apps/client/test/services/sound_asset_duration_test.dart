import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for #1156.
///
/// Some platform audio backends (Android `MediaPlayer`, Windows
/// `MediaFoundation`) silently swallow OGG clips that finish inside one
/// playback buffer (~100–200 ms). The original `received.ogg` / `sent.ogg`
/// shipped at 78 ms and were inaudible on every desktop / mobile target;
/// only the voice-lounge sounds (300 ms) played reliably. We pad message
/// sounds to ≥ 300 ms so they clear the threshold on every backend.
///
/// This test parses the last OGG page's granule position (the cumulative
/// sample count) and asserts the file represents at least 200 ms of audio
/// at 44.1 kHz, catching any future re-encode that drops below the cliff.
const int _minSamples = 200 * 44100 ~/ 1000; // 8820 samples (200 ms @ 44.1 kHz)

int _lastOggGranulePosition(File f) {
  final bytes = f.readAsBytesSync();
  var lastGranule = 0;
  for (var i = 0; i + 14 <= bytes.length; i++) {
    // 'OggS' magic = 0x4F 0x67 0x67 0x53.
    if (bytes[i] == 0x4F &&
        bytes[i + 1] == 0x67 &&
        bytes[i + 2] == 0x67 &&
        bytes[i + 3] == 0x53) {
      final granule = ByteData.sublistView(
        bytes,
        i + 6,
        i + 14,
      ).getInt64(0, Endian.little);
      // Granule -1 marks a continued packet — ignore, prefer the last
      // resolved position.
      if (granule >= 0) lastGranule = granule;
    }
  }
  return lastGranule;
}

void main() {
  group('bundled notification-sound assets', () {
    test('received.ogg is long enough to be audible (>= 200 ms)', () {
      final granule = _lastOggGranulePosition(
        File('assets/sounds/received.ogg'),
      );
      expect(
        granule,
        greaterThanOrEqualTo(_minSamples),
        reason:
            'received.ogg must be at least 200 ms — shorter clips are '
            'inaudible on most platform audio backends (#1156).',
      );
    });

    test('sent.ogg is long enough to be audible (>= 200 ms)', () {
      final granule = _lastOggGranulePosition(File('assets/sounds/sent.ogg'));
      expect(
        granule,
        greaterThanOrEqualTo(_minSamples),
        reason:
            'sent.ogg must be at least 200 ms — shorter clips are '
            'inaudible on most platform audio backends (#1156).',
      );
    });
  });
}
