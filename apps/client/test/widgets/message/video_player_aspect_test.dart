// Unit tests for resolveInlineAspectRatio (#12).
//
// The inline video bubble used to hard-code 16:9 regardless of the video's
// actual dimensions. Portrait/vertical videos were letterboxed and tiny.
// resolveInlineAspectRatio() now returns the real w/h ratio once the codec
// reports dimensions, falling back to 16:9 while initialising.
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/video_player.dart';

void main() {
  group('resolveInlineAspectRatio (#12)', () {
    test('returns 16/9 when dimensions are not yet known (0, 0)', () {
      final ratio = resolveInlineAspectRatio(0, 0);
      expect(ratio, closeTo(16 / 9, 0.001));
    });

    test('returns 16/9 when width is 0 but height is set', () {
      final ratio = resolveInlineAspectRatio(0, 1080);
      expect(ratio, closeTo(16 / 9, 0.001));
    });

    test('returns 16/9 when height is 0 but width is set', () {
      final ratio = resolveInlineAspectRatio(1920, 0);
      expect(ratio, closeTo(16 / 9, 0.001));
    });

    test('returns correct ratio for landscape 1920x1080', () {
      final ratio = resolveInlineAspectRatio(1920, 1080);
      expect(ratio, closeTo(16 / 9, 0.001));
    });

    test('returns correct ratio for portrait 1080x1920 (9:16)', () {
      final ratio = resolveInlineAspectRatio(1080, 1920);
      expect(ratio, closeTo(9 / 16, 0.001));
    });

    test('returns correct ratio for square 1080x1080', () {
      final ratio = resolveInlineAspectRatio(1080, 1080);
      expect(ratio, closeTo(1.0, 0.001));
    });

    test('clamps extremely wide video to max 5.0', () {
      final ratio = resolveInlineAspectRatio(10000, 100);
      expect(ratio, equals(5.0));
    });

    test('clamps extremely tall video to min 0.3', () {
      final ratio = resolveInlineAspectRatio(100, 10000);
      expect(ratio, equals(0.3));
    });

    test('returns correct ratio for 4:3 (1440x1080)', () {
      final ratio = resolveInlineAspectRatio(1440, 1080);
      expect(ratio, closeTo(4 / 3, 0.001));
    });

    test('returns correct ratio for vertical short-form 1080x1350 (4:5)', () {
      final ratio = resolveInlineAspectRatio(1080, 1350);
      expect(ratio, closeTo(1080 / 1350, 0.001));
    });
  });
}
