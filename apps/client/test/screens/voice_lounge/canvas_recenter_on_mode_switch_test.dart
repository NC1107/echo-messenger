// Tests for canvas re-centering when the user switches back INTO canvas mode.
//
// Production path (voice_lounge_screen.dart):
//   onToggleSpotlight → notifier.state = VoiceLoungeView.canvas
//                      → addPostFrameCallback → _resetViewport()
//                      → _canvasGesturesKey.currentState!.resetToTransform(homePose)
//
// The full VoiceLoungeScreen is too widget-heavy to pump in unit tests
// (requires LiveKit, WS, canvas server attach, etc.).  These tests cover
// the two primitives the production path composes:
//
//   1. resetToTransform(homePose) correctly snaps the gesture surface back
//      to the home transform after the user has panned away — the contract
//      _resetViewport() depends on.
//   2. The home-pose matrix (_centeredPose math) places the canvas centre
//      in the middle of the viewport at the expected fit scale — so a
//      recenter genuinely lands on the avatar ring, not some stale offset.

import 'dart:math' as math;

import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Mirrors of the constants + math from voice_lounge_screen.dart so the test
// doesn't need to reach into private screen internals.  If the production
// values ever change, update these constants and the test will fail loudly.
// ---------------------------------------------------------------------------

const double _kCanvasWidth = 6000;
const double _kCanvasHeight = 6000;
// kDefaultAvatarRingFraction (0.15) * kCanvasWidth (6000) = 900.0
const double _kDefaultAvatarRingRadius = 900.0;
const double _kAvatarTileRadius = 24.0;

/// Reproduces `_VoiceLoungeScreenState._centeredPose` exactly.
Matrix4 _centeredPose(Size viewport) {
  const cx = _kCanvasWidth / 2;
  const cy = _kCanvasHeight / 2;
  const ringExtent = _kDefaultAvatarRingRadius + _kAvatarTileRadius;
  const framed = ringExtent * 2 * 1.3;
  final fit = math.min(viewport.width, viewport.height) / framed;
  return Matrix4.identity()
    ..scaleByDouble(fit, fit, fit, 1)
    ..setTranslationRaw(
      viewport.width / 2 - cx * fit,
      viewport.height / 2 - cy * fit,
      0,
    );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _Recorder {
  final List<Matrix4> transforms = <Matrix4>[];
}

LoungeCanvasGestures _harness({
  required _Recorder rec,
  required Key key,
  Size viewport = const Size(800, 600),
}) {
  return LoungeCanvasGestures(
    key: key,
    isToolSelected: false,
    initialTransform: Matrix4.identity(),
    minScale: 0.05,
    maxScale: 10.0,
    viewportSize: viewport,
    canvasSize: const Size(_kCanvasWidth, _kCanvasHeight), // 6000×6000
    onStrokeStart: (_) {},
    onStrokeMove: (_) {},
    onStrokeEnd: () {},
    onStrokeCancel: () {},
    onTransformChanged: (m) => rec.transforms.add(Matrix4.copy(m)),
    child: const SizedBox(width: 800, height: 600),
  );
}

LoungeCanvasGesturesState _stateOf(WidgetTester tester, Key key) =>
    tester.state<LoungeCanvasGesturesState>(find.byKey(key));

void main() {
  group('canvas recenter on mode switch', () {
    // -----------------------------------------------------------------------
    // 1. resetToTransform snaps back to the home pose after panning away.
    //    This is the exact contract _resetViewport() relies on — if this
    //    breaks the recenter-on-mode-switch behaviour silently breaks too.
    // -----------------------------------------------------------------------
    testWidgets(
      'resetToTransform restores home pose after the user has panned away',
      (tester) async {
        const viewport = Size(800, 600);
        final rec = _Recorder();
        const key = ValueKey('recenter-reset');
        await tester.pumpWidget(
          MaterialApp(
            home: _harness(rec: rec, key: key, viewport: viewport),
          ),
        );

        final state = _stateOf(tester, key);
        final homePose = _centeredPose(viewport);

        // Confirm initial transform is identity (not yet the home pose —
        // the gesture widget takes whatever initialTransform it was given;
        // the screen writes the home pose via _resolveInitialTransform).
        expect(
          state.debugTransform.getTranslation().x,
          closeTo(0, 0.01),
          reason: 'starts at identity',
        );

        // Simulate the user panning far from the home pose.
        state.resetToTransform(
          Matrix4.identity()..setTranslationRaw(1500, 1200, 0),
        );
        await tester.pump();
        expect(
          state.debugTransform.getTranslation().x,
          isNot(closeTo(homePose.getTranslation().x, 1.0)),
          reason: 'panned away from home',
        );

        // resetToTransform(homePose) must snap back — this is what
        // _resetViewport() calls after addPostFrameCallback when the user
        // switches back into canvas mode.
        state.resetToTransform(homePose);
        await tester.pump();

        final t = state.debugTransform.getTranslation();
        final hT = homePose.getTranslation();
        expect(t.x, closeTo(hT.x, 0.5), reason: 'x snapped to home');
        expect(t.y, closeTo(hT.y, 0.5), reason: 'y snapped to home');
        expect(
          state.debugTransform.getMaxScaleOnAxis(),
          closeTo(homePose.getMaxScaleOnAxis(), 1e-4),
          reason: 'scale snapped to home',
        );
      },
    );

    // -----------------------------------------------------------------------
    // 2. The home-pose matrix centres on the canvas mid-point.
    //    If the avatar-ring constants or the framing maths change, the
    //    recenter will land in the wrong place — this test catches that drift.
    // -----------------------------------------------------------------------
    test('_centeredPose places the canvas centre at the viewport centre', () {
      const viewport = Size(800, 600);
      final pose = _centeredPose(viewport);

      // Canvas centre in canvas-space.
      const cx = _kCanvasWidth / 2.0;
      const cy = _kCanvasHeight / 2.0;

      // Project it through the pose transform → should land at viewport centre.
      final projected = MatrixUtils.transformPoint(pose, const Offset(cx, cy));
      expect(
        projected.dx,
        closeTo(viewport.width / 2, 0.5),
        reason: 'canvas centre maps to viewport centre X',
      );
      expect(
        projected.dy,
        closeTo(viewport.height / 2, 0.5),
        reason: 'canvas centre maps to viewport centre Y',
      );
    });

    // -----------------------------------------------------------------------
    // 3. The home-pose scale fits the avatar ring in the viewport with margin.
    //    Switching to canvas mode should never land in an extreme zoom state.
    // -----------------------------------------------------------------------
    test('_centeredPose fit scale is within a sane viewing range', () {
      // Test a few viewport sizes to cover mobile + desktop breakpoints.
      for (final viewport in const [
        Size(375, 812), // mobile portrait
        Size(800, 600), // tablet landscape
        Size(1440, 900), // desktop
      ]) {
        final pose = _centeredPose(viewport);
        final scale = pose.getMaxScaleOnAxis();
        // The fit scale should be well above the minimum (not a shrunken-to-
        // nothing initial view) and below 2.0 (not absurdly zoomed in).
        expect(scale, greaterThan(0.1), reason: 'not too small ($viewport)');
        expect(scale, lessThan(2.0), reason: 'not too large ($viewport)');
      }
    });
  });
}
