// ORPHANED 2026-05-28: replaced by `widgets/voice_lounge/lounge_canvas_gestures.dart`
// + `widgets/voice_lounge/lounge_canvas_strokes.dart` during the canvas
// rewrite (see docs/voice-lounge/05-canvas-rewrite-spec.md). The voice
// lounge screen no longer mounts this widget. Kept temporarily so the
// existing widget-test in test/widgets/lounge_drawing_canvas_test.dart and
// the gesture-arbitration test in test/screens/voice_lounge/
// canvas_gesture_arbitration_test.dart still compile; the next cleanup
// PR deletes both this file and those tests.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/canvas_models.dart';
import '../providers/canvas_provider.dart';

/// Single-pointer drawing overlay for the voice lounge canvas.
///
/// Previously used [Listener] with [HitTestBehavior.opaque] which ate ALL
/// pointer events — including the second finger of a pinch — before the
/// parent [InteractiveViewer]'s `ScaleGestureRecognizer` could claim them.
/// That killed pinch-to-zoom on mobile (user feedback, 2026-05-27).
///
/// Now uses [GestureDetector]'s `onPan*` callbacks. Flutter's
/// `PanGestureRecognizer` accepts exactly one pointer; a second touch
/// causes the pan to lose the gesture arena, letting InteractiveViewer's
/// scale recogniser take over so pinch-to-zoom works.
class LoungeDrawingCanvas extends ConsumerStatefulWidget {
  final bool isActive;

  const LoungeDrawingCanvas({super.key, required this.isActive});

  @override
  ConsumerState<LoungeDrawingCanvas> createState() =>
      LoungeDrawingCanvasState();
}

class LoungeDrawingCanvasState extends ConsumerState<LoungeDrawingCanvas> {
  /// Pointer events arrive in the InteractiveViewer-scaled child's
  /// coordinate space — absolute pixels in the 4096×4096 surface. We
  /// clamp and pass through; no per-viewport scaling is needed.
  CanvasPoint _toCanvasPoint(Offset canvasSpace) {
    return CanvasPoint(
      x: canvasSpace.dx.clamp(0.0, kCanvasWidth),
      y: canvasSpace.dy.clamp(0.0, kCanvasHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Default `DragStartBehavior.start` (NOT `.down`) — `.down` claimed
      // the gesture arena immediately on first-pointer-down, which
      // blocked the parent InteractiveViewer's ScaleGestureRecognizer
      // from ever taking over a two-finger pinch. With `.start`, the pan
      // recogniser waits for a few pixels of slop before claiming, which
      // gives the multi-touch path a window to assert ownership. Strokes
      // have a tiny startup delay (kPanSlop ≈ 18 px) but pinch-to-zoom
      // works on mobile again — see user feedback 2026-05-28.
      onPanStart: (details) {
        ref
            .read(canvasProvider.notifier)
            .startStroke(_toCanvasPoint(details.localPosition));
      },
      onPanUpdate: (details) {
        ref
            .read(canvasProvider.notifier)
            .continueStroke(_toCanvasPoint(details.localPosition));
      },
      onPanEnd: (_) {
        ref.read(canvasProvider.notifier).endStroke();
      },
      onPanCancel: () {
        ref.read(canvasProvider.notifier).endStroke();
      },
      child: const SizedBox.expand(),
    );
  }
}
