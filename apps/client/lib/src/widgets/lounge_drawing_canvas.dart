import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/canvas_models.dart';
import '../providers/canvas_provider.dart';

/// Transparent pointer-capture overlay for freehand drawing in the voice
/// lounge.
///
/// All stroke state (in-progress + committed) is owned by [canvasProvider]
/// so it broadcasts to other participants and persists.  This widget is
/// purely a pointer router: when [isActive] is true it sits above the voice
/// canvas, captures pointer events that would otherwise hit avatars or
/// shared-screen tiles, and forwards them to the provider as normalized
/// `CanvasPoint`s.
///
/// Rendering of strokes (committed and in-progress) happens in
/// `widgets/voice_canvas.dart`'s `_DrawingLayer`, which subscribes to the
/// same provider state.  Without this overlay, drawing-mode pointer events
/// would race with avatar drag handlers and stroke broadcast was previously
/// not happening at all (#752).
class LoungeDrawingCanvas extends ConsumerStatefulWidget {
  final bool isActive;

  const LoungeDrawingCanvas({super.key, required this.isActive});

  @override
  ConsumerState<LoungeDrawingCanvas> createState() =>
      LoungeDrawingCanvasState();
}

class LoungeDrawingCanvasState extends ConsumerState<LoungeDrawingCanvas> {
  /// Pointer events delivered to this Listener arrive in the
  /// InteractiveViewer-scaled child's coordinate space — i.e. absolute
  /// canvas-space pixels in the 4096×4096 surface. We just clamp and pass
  /// through; no per-viewport scaling is needed.
  CanvasPoint _toCanvasPoint(Offset canvasSpace) {
    return CanvasPoint(
      x: canvasSpace.dx.clamp(0.0, kCanvasWidth),
      y: canvasSpace.dy.clamp(0.0, kCanvasHeight),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    ref
        .read(canvasProvider.notifier)
        .startStroke(_toCanvasPoint(event.localPosition));
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.buttons != kPrimaryButton) return;
    ref
        .read(canvasProvider.notifier)
        .continueStroke(_toCanvasPoint(event.localPosition));
  }

  void _onPointerUp(PointerUpEvent event) {
    ref.read(canvasProvider.notifier).endStroke();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    ref.read(canvasProvider.notifier).endStroke();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) return const SizedBox.shrink();
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: const SizedBox.expand(),
    );
  }
}
