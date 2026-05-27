import 'package:flutter/gestures.dart';
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
      // DragStartBehavior.down so the inner pan claims the gesture arena
      // immediately on pointer-down instead of waiting for slop —
      // otherwise a fast first stroke can get reclassified.
      dragStartBehavior: DragStartBehavior.down,
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
