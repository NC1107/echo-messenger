import 'package:echo_app/src/theme/responsive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Responsive.layoutTier', () {
    test('classifies widths into the three tiers', () {
      expect(Responsive.layoutTier(320), LayoutTier.narrow);
      expect(Responsive.layoutTier(599.9), LayoutTier.narrow);
      expect(Responsive.layoutTier(600), LayoutTier.wide);
      expect(Responsive.layoutTier(899.9), LayoutTier.wide);
      expect(Responsive.layoutTier(900), LayoutTier.desktop);
      expect(Responsive.layoutTier(1920), LayoutTier.desktop);
    });
  });

  group('StableLayoutDecision', () {
    test('first call seeds from raw breakpoints', () {
      expect(StableLayoutDecision().next(500), LayoutTier.narrow);
      expect(StableLayoutDecision().next(700), LayoutTier.wide);
      expect(StableLayoutDecision().next(1100), LayoutTier.desktop);
    });

    test('stays in narrow until width clears 600 + hysteresis', () {
      final d = StableLayoutDecision()..next(500);
      // Within the hysteresis band just past 600 -- should stay narrow.
      expect(d.next(610), LayoutTier.narrow);
      expect(d.next(619), LayoutTier.narrow);
      // Past the OUT edge -- flips to wide.
      expect(d.next(621), LayoutTier.wide);
    });

    test('stays in desktop until width drops below 900 - hysteresis', () {
      final d = StableLayoutDecision()..next(1100);
      // Just under 900 but inside the hysteresis band -- stay desktop.
      expect(d.next(890), LayoutTier.desktop);
      expect(d.next(881), LayoutTier.desktop);
      // Past the OUT edge -- flips to wide.
      expect(d.next(879), LayoutTier.wide);
    });

    test('wide tier is sticky around both seams', () {
      final d = StableLayoutDecision()..next(750);
      // Crossing 600 downward inside the band -- stay wide.
      expect(d.next(590), LayoutTier.wide);
      expect(d.next(581), LayoutTier.wide);
      expect(d.next(579), LayoutTier.narrow);
      // Reset to wide.
      d.next(750);
      // Crossing 900 upward inside the band -- stay wide.
      expect(d.next(910), LayoutTier.wide);
      expect(d.next(919), LayoutTier.wide);
      expect(d.next(921), LayoutTier.desktop);
    });

    test('does not flicker when oscillating near a breakpoint', () {
      // Simulate a user dragging the window edge back and forth across 600
      // by a few pixels. Without hysteresis this oscillates wildly; with
      // hysteresis we should stick in narrow the whole time.
      final d = StableLayoutDecision()..next(595);
      for (final w in [599.0, 601.0, 604.0, 599.0, 610.0, 605.0]) {
        expect(
          d.next(w),
          LayoutTier.narrow,
          reason: 'should stay narrow at width=$w (inside hysteresis band)',
        );
      }
    });
  });
}
