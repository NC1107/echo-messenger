import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/livekit_voice/stream_quality_preset.dart';

void main() {
  group('StreamQuality preset mapping', () {
    test('every manual preset has entries in kStreamQualityParams', () {
      const manualPresets = [
        StreamQuality.sd,
        StreamQuality.hd,
        StreamQuality.fullHd,
        StreamQuality.ultra,
      ];
      for (final preset in manualPresets) {
        expect(
          kStreamQualityParams.containsKey(preset),
          isTrue,
          reason: '${preset.name} must have a params entry',
        );
      }
      // auto has no params entry by design
      expect(kStreamQualityParams.containsKey(StreamQuality.auto), isFalse);
    });

    test('every preset has a long label', () {
      for (final preset in StreamQuality.values) {
        expect(
          kStreamQualityLabel.containsKey(preset),
          isTrue,
          reason: '${preset.name} must have a long label',
        );
        expect(kStreamQualityLabel[preset], isNotEmpty);
      }
    });

    test('every preset has a short label of at most 6 chars', () {
      for (final preset in StreamQuality.values) {
        expect(
          kStreamQualityShortLabel.containsKey(preset),
          isTrue,
          reason: '${preset.name} must have a short label',
        );
        final label = kStreamQualityShortLabel[preset]!;
        expect(
          label.length,
          lessThanOrEqualTo(6),
          reason: 'Short label "$label" for ${preset.name} exceeds 6 chars',
        );
      }
    });

    test('bitrates are ordered SD < HD < Full HD < Ultra', () {
      final sd = kStreamQualityParams[StreamQuality.sd]!.bitrate;
      final hd = kStreamQualityParams[StreamQuality.hd]!.bitrate;
      final fhd = kStreamQualityParams[StreamQuality.fullHd]!.bitrate;
      final ultra = kStreamQualityParams[StreamQuality.ultra]!.bitrate;

      expect(sd, lessThan(hd));
      expect(hd, lessThan(fhd));
      expect(fhd, lessThan(ultra));
    });

    test('SD bitrate is ~500 kbps', () {
      expect(kStreamQualityParams[StreamQuality.sd]!.bitrate, 500000);
    });

    test('HD bitrate is ~1.5 Mbps', () {
      expect(kStreamQualityParams[StreamQuality.hd]!.bitrate, 1500000);
    });

    test('Full HD bitrate is ~2.5 Mbps', () {
      expect(kStreamQualityParams[StreamQuality.fullHd]!.bitrate, 2500000);
    });

    test('Ultra bitrate is ~5 Mbps', () {
      expect(kStreamQualityParams[StreamQuality.ultra]!.bitrate, 5000000);
    });

    test('all manual presets run at 30 fps', () {
      for (final preset in [
        StreamQuality.sd,
        StreamQuality.hd,
        StreamQuality.fullHd,
        StreamQuality.ultra,
      ]) {
        expect(
          kStreamQualityParams[preset]!.fps,
          30,
          reason: '${preset.name} should run at 30 fps',
        );
      }
    });
  });

  group('streamQualityFromString', () {
    test('round-trips every enum value', () {
      for (final preset in StreamQuality.values) {
        expect(streamQualityFromString(preset.name), preset);
      }
    });

    test('falls back to auto for unknown strings', () {
      expect(streamQualityFromString(''), StreamQuality.auto);
      expect(streamQualityFromString('bogus'), StreamQuality.auto);
      expect(
        streamQualityFromString('Ultra'),
        StreamQuality.auto,
      ); // case-sensitive
    });
  });
}
