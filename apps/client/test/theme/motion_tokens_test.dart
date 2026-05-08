import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/motion_tokens.dart';

void main() {
  group('MotionDurations', () {
    test('tokens are strictly ordered fastest -> slowest', () {
      // Catches accidental reordering / typo — if someone edits a
      // token to a wrong value, this test localizes the regression.
      const ordered = [
        MotionDurations.instant,
        MotionDurations.quick,
        MotionDurations.standard,
        MotionDurations.expressive,
        MotionDurations.gentle,
        MotionDurations.pulse,
      ];
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i].inMilliseconds,
          greaterThan(ordered[i - 1].inMilliseconds),
          reason: 'token at index $i must be slower than index ${i - 1}',
        );
      }
    });

    test('all durations are positive', () {
      const all = [
        MotionDurations.instant,
        MotionDurations.quick,
        MotionDurations.standard,
        MotionDurations.expressive,
        MotionDurations.gentle,
        MotionDurations.pulse,
      ];
      for (final d in all) {
        expect(d.inMilliseconds, greaterThan(0));
      }
    });

    test('pulse is suitable for ambient motion (>=500ms)', () {
      // Pulse is reserved for continuous, breathing motion.  If
      // someone accidentally aliases it to a faster value, motion
      // designed against it (speaking ring) will start strobing.
      expect(MotionDurations.pulse.inMilliseconds, greaterThanOrEqualTo(500));
    });

    test('instant is fast enough for hover feedback (<=120ms)', () {
      // Hover responses below ~120ms feel synchronous; above that
      // they read as "loading."
      expect(MotionDurations.instant.inMilliseconds, lessThanOrEqualTo(120));
    });
  });

  group('MotionCurves', () {
    test('entrance and exit are distinct curves', () {
      // Easy regression: collapsing entrance/exit to the same curve
      // makes UI feel "linear" / robotic.
      expect(MotionCurves.entrance, isNot(equals(MotionCurves.exit)));
    });

    test('all curves are non-null Curve instances', () {
      const curves = <Curve>[
        MotionCurves.entrance,
        MotionCurves.exit,
        MotionCurves.emphasis,
        MotionCurves.expressiveBounce,
        MotionCurves.decelerate,
      ];
      for (final c in curves) {
        expect(c, isA<Curve>());
      }
    });

    test('expressiveBounce overshoots above 1.0', () {
      // The whole point of the expressive bounce is that it goes
      // *past* the target before settling.  If someone "fixes" it to
      // a non-overshooting curve, this catches the regression.
      var maxValue = 0.0;
      for (var t = 0.0; t <= 1.0; t += 0.01) {
        final v = MotionCurves.expressiveBounce.transform(t);
        if (v > maxValue) maxValue = v;
      }
      expect(maxValue, greaterThan(1.0));
    });

    test('entrance ends at 1.0 and starts at 0.0', () {
      expect(MotionCurves.entrance.transform(0.0), closeTo(0.0, 1e-6));
      expect(MotionCurves.entrance.transform(1.0), closeTo(1.0, 1e-6));
    });
  });
}
