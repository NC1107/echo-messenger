import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

/// Pixel drag delta for [DraggableCanvasItem] move/resize, in the parent's
/// coordinate space. Each caller maps it onward — images to the 4096-px canvas
/// space, screen-share windows to viewport CSS pixels.
typedef CanvasItemDragDelta = void Function(double dx, double dy);

/// Move + resize gesture callbacks for [DraggableCanvasItem].
///
/// Grouped into one object so the widget constructor stays within the 7-param
/// budget (S107), and so the (intentionally different) semantics each caller
/// attaches — `CanvasDragScope` suppression for images, position broadcast for
/// screen-share windows — live with the caller rather than the frame.
@immutable
class CanvasItemGestures {
  /// Fired on move pointer-down, before the first delta. Images use it to
  /// suppress canvas panning; screen-share windows leave it null.
  final VoidCallback? onMoveStart;

  /// Fired for each move delta.
  final CanvasItemDragDelta onMove;

  /// Fired when the move drag ends normally.
  final VoidCallback onMoveEnd;

  /// Fired when the move drag is cancelled (pointer lost). Images use it to
  /// release the drag-scope without committing a move.
  final VoidCallback? onMoveCancel;

  /// Fired for each resize delta. When null, no resize handle is rendered even
  /// if [DraggableCanvasItem.resizeHandle] is supplied.
  final CanvasItemDragDelta? onResize;

  /// Fired when the resize drag ends / is cancelled.
  final VoidCallback? onResizeEnd;
  final VoidCallback? onResizeCancel;

  const CanvasItemGestures({
    required this.onMove,
    required this.onMoveEnd,
    this.onMoveStart,
    this.onMoveCancel,
    this.onResize,
    this.onResizeEnd,
    this.onResizeCancel,
  });
}

/// Behaviour-only frame for a draggable + resizable item on the lounge canvas
/// (images, screen-share windows, and future video clips).
///
/// Centralises the gesture scaffolding those items used to hand-roll
/// identically:
///   * hover tracking that gates the overlays;
///   * a move drag that wins the gesture arena on pointer-down
///     ([DragStartBehavior.down]) so a fast drag can't be stolen mid-gesture by
///     the canvas pan recognizer (#22 / user report 2026-05-27);
///   * a hover-gated bottom-right resize handle with a resize cursor.
///
/// It deliberately knows nothing about coordinate spaces, persistence, aspect
/// locking, or broadcasting — all of that stays in [gestures] so each caller
/// keeps its own semantics. [child] carries its own decoration/clipping and is
/// sized by the parent's constraints: the Stack uses [StackFit.passthrough], so
/// a parent giving tight constraints (an image in a sized `Positioned`) makes
/// the child fill, while a self-sizing child (a screen-share `Container` under a
/// loose `Positioned`) keeps its intrinsic size.
class DraggableCanvasItem extends StatefulWidget {
  /// The decorated, sized body. Owns its own border/shadow/clipping.
  final Widget child;

  final CanvasItemGestures gestures;

  /// Cursor shown while hovering the movable body.
  final MouseCursor moveCursor;

  /// Single hover-only overlay stacked above [child] — a close button for
  /// images, a label badge for screen shares. Built only while hovered, so
  /// callers don't re-check hover state. Should return a positioned widget.
  final WidgetBuilder? hoverOverlayBuilder;

  /// Visual for the resize handle (callers differ: a filled chip vs a bare
  /// icon). Rendered at the bottom-right corner, hover-gated, and only when
  /// [CanvasItemGestures.onResize] is non-null.
  final Widget? resizeHandle;

  const DraggableCanvasItem({
    super.key,
    required this.child,
    required this.gestures,
    this.moveCursor = SystemMouseCursors.move,
    this.hoverOverlayBuilder,
    this.resizeHandle,
  });

  @override
  State<DraggableCanvasItem> createState() => _DraggableCanvasItemState();
}

class _DraggableCanvasItemState extends State<DraggableCanvasItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.gestures;
    final showResize = g.onResize != null && widget.resizeHandle != null;
    return MouseRegion(
      cursor: widget.moveCursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: g.onMoveStart == null ? null : (_) => g.onMoveStart!(),
        onPanUpdate: (d) => g.onMove(d.delta.dx, d.delta.dy),
        onPanEnd: (_) => g.onMoveEnd(),
        onPanCancel: g.onMoveCancel,
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_hovered && widget.hoverOverlayBuilder != null)
              widget.hoverOverlayBuilder!(context),
            if (_hovered && showResize)
              Positioned(
                right: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: GestureDetector(
                    dragStartBehavior: DragStartBehavior.down,
                    onPanUpdate: (d) => g.onResize!(d.delta.dx, d.delta.dy),
                    onPanEnd: g.onResizeEnd == null
                        ? null
                        : (_) => g.onResizeEnd!(),
                    onPanCancel: g.onResizeCancel,
                    child: widget.resizeHandle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
