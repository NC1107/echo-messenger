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
  Size _canvasSize = Size.zero;

  CanvasPoint _toNormalized(Offset pixel) {
    final w = _canvasSize.width;
    final h = _canvasSize.height;
    if (w <= 0 || h <= 0) return const CanvasPoint(x: 0, y: 0);
    return CanvasPoint(
      x: (pixel.dx / w).clamp(0.0, 1.0),
      y: (pixel.dy / h).clamp(0.0, 1.0),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    ref
        .read(canvasProvider.notifier)
        .startStroke(_toNormalized(event.localPosition));
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.buttons != kPrimaryButton) return;
    ref
        .read(canvasProvider.notifier)
        .continueStroke(_toNormalized(event.localPosition));
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
