// Pure unit tests for [clampAxis] — the per-axis overscroll-margin helper
// extracted from LoungeCanvasGestures._clampTransform.
//
// No widget harness required; the function is a plain Dart computation.
// Tests cover the three scenarios described in the fix:
//   1. Zoomed in  (scaledContent > viewport) — edges reachable but not losable.
//   2. Zoomed out (scaledContent < viewport) — panning allowed, margin kept.
//   3. Extreme translations — clamped on both lo and hi sides.

import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // clampAxis(tx, scale, viewport, content, marginFraction)
  //
  // margin = min(content*scale, viewport) * marginFraction
  // lo     = margin - content*scale
  // hi     = viewport - margin
  // result = tx.clamp(lo, hi)

  group('clampAxis — zoomed in (scaledContent > viewport)', () {
    // scaled = 1000, viewport = 800, marginFraction = 0.15
    // margin = 800 * 0.15 = 120
    // lo = 120 - 1000 = -880
    // hi = 800 - 120  =  680
    const scale = 1.0;
    const viewport = 800.0;
    const content = 1000.0;
    const fraction = 0.15;

    test('translation within bounds is unchanged', () {
      expect(
        clampAxis(-400, scale, viewport, content, fraction),
        closeTo(-400, 0.001),
      );
      expect(
        clampAxis(0, scale, viewport, content, fraction),
        closeTo(0, 0.001),
      );
    });

    test('translation past lo is clamped to lo (-880)', () {
      expect(
        clampAxis(-2000, scale, viewport, content, fraction),
        closeTo(-880, 0.001),
        reason: 'board must stay at least margin (120px) visible on the right',
      );
    });

    test('translation past hi is clamped to hi (680)', () {
      expect(
        clampAxis(1000, scale, viewport, content, fraction),
        closeTo(680, 0.001),
        reason: 'board must stay at least margin (120px) visible on the left',
      );
    });

    test('lo boundary is exactly reachable (not exclusive)', () {
      expect(
        clampAxis(-880, scale, viewport, content, fraction),
        closeTo(-880, 0.001),
      );
    });

    test('hi boundary is exactly reachable (not exclusive)', () {
      expect(
        clampAxis(680, scale, viewport, content, fraction),
        closeTo(680, 0.001),
      );
    });
  });

  group('clampAxis — zoomed out (scaledContent < viewport)', () {
    // scaled = 400, viewport = 800, marginFraction = 0.15
    // margin = 400 * 0.15 = 60
    // lo = 60 - 400 = -340
    // hi = 800 - 60  =  740
    const scale = 1.0;
    const viewport = 800.0;
    const content = 400.0;
    const fraction = 0.15;

    test('panning left (negative tx) is allowed within margin', () {
      // tx = -100 is well within lo (-340) — should NOT be force-centred.
      expect(
        clampAxis(-100, scale, viewport, content, fraction),
        closeTo(-100, 0.001),
        reason: 'zoomed-out panning must not be force-centred (#29 regression)',
      );
    });

    test('panning right (positive tx) is allowed within margin', () {
      expect(
        clampAxis(200, scale, viewport, content, fraction),
        closeTo(200, 0.001),
      );
    });

    test('translation past lo (-340) is clamped', () {
      expect(
        clampAxis(-500, scale, viewport, content, fraction),
        closeTo(-340, 0.001),
        reason: 'board must keep at least 60px visible on the right (#30)',
      );
    });

    test('translation past hi (740) is clamped', () {
      expect(
        clampAxis(900, scale, viewport, content, fraction),
        closeTo(740, 0.001),
        reason: 'board must keep at least 60px visible on the left (#30)',
      );
    });

    test('tx = 0 (flush left) is valid — no force-centre', () {
      expect(
        clampAxis(0, scale, viewport, content, fraction),
        closeTo(0, 0.001),
      );
    });
  });

  group('clampAxis — scale != 1', () {
    // scale=0.5, content=1000 → scaled=500, viewport=800
    // margin = 500 * 0.15 = 75
    // lo = 75 - 500 = -425
    // hi = 800 - 75  =  725
    test('respects scale when computing lo/hi', () {
      expect(clampAxis(-500, 0.5, 800, 1000, 0.15), closeTo(-425, 0.001));
      expect(clampAxis(800, 0.5, 800, 1000, 0.15), closeTo(725, 0.001));
    });
  });

  group('clampAxis — degenerate / edge cases', () {
    test('returns midpoint when lo >= hi (zero-size content)', () {
      // content=0 → scaled=0, margin=0, lo=0, hi=viewport — normal range.
      // But with content near-zero and fraction=1.0, lo=hi at viewport/2.
      // Specifically: content=0 → scaled=0 < viewport → margin=0*fraction=0
      // → lo=0, hi=viewport. Valid range, clamps normally.
      expect(clampAxis(0, 1.0, 800, 0, 0.15), closeTo(0, 0.001));
    });

    test('extreme negative tx is clamped to lo', () {
      expect(clampAxis(-1e9, 1.0, 800, 400, 0.15), closeTo(-340, 0.001));
    });

    test('extreme positive tx is clamped to hi', () {
      expect(clampAxis(1e9, 1.0, 800, 400, 0.15), closeTo(740, 0.001));
    });
  });
}
