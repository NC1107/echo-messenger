// On-canvas debug overlay for the voice lounge.
//
// Renders a dashed border around the gesture surface plus two HUD pills:
//
//   - Top-left:  gesture phase + transform scale/translate + pointer count.
//   - Top-right: committed stroke count + active stroke point count +
//                image count + avatar count + attach state + active tool.
//
// Mounted by voice_lounge_screen.dart inside an IgnorePointer so it
// never interferes with the canvas gesture surface. Gated behind the
// `_kDebugCanvas` flag at the top of that file. Do NOT ship that flag
// flipped to `true`.
//
// Added in response to user feedback 2026-05-29 on the canvas rewrite
// live test ("can we add some more debug info? and maybe render the
// canvas with a border to help debug some problems").

import 'package:flutter/material.dart';

import '../../models/canvas_models.dart';
import 'canvas_gesture_state.dart';
import 'lounge_canvas_gestures.dart';

/// Debug HUD layered over the lounge canvas. Always wrap in
/// IgnorePointer; callers must NOT mount this in release builds.
class CanvasDebugOverlay extends StatelessWidget {
  final GlobalKey<LoungeCanvasGesturesState> gesturesKey;
  final CanvasState canvas;
  final int activeStrokePointCount;
  final Color borderColor;

  const CanvasDebugOverlay({
    super.key,
    required this.gesturesKey,
    required this.canvas,
    required this.activeStrokePointCount,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DashedBorderPainter(color: borderColor),
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: _LeftHud(gesturesKey: gesturesKey),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: _RightHud(
              canvas: canvas,
              activeStrokePointCount: activeStrokePointCount,
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-left HUD. Subscribes to the gesture widget's phase notifier so
/// it repaints on every transition without rebuilding the lounge.
class _LeftHud extends StatelessWidget {
  final GlobalKey<LoungeCanvasGesturesState> gesturesKey;
  const _LeftHud({required this.gesturesKey});

  @override
  Widget build(BuildContext context) {
    final state = gesturesKey.currentState;
    if (state == null) {
      return const _DebugPill(text: 'gestures: not mounted');
    }
    return ValueListenableBuilder<CanvasGesturePhase>(
      valueListenable: state.phaseListenable,
      builder: (context, phase, _) {
        final t = state.debugTransform;
        final scale = t.getMaxScaleOnAxis();
        final trans = t.getTranslation();
        final lines = <String>[
          'phase: ${phase.name}',
          'scale: ${scale.toStringAsFixed(3)}',
          'tx: ${trans.x.toStringAsFixed(1)}  ty: ${trans.y.toStringAsFixed(1)}',
          'pointers: ${state.debugPointerCount}',
        ];
        return _DebugPill(text: lines.join('\n'));
      },
    );
  }
}

/// Top-right HUD with canvas-content counts.
class _RightHud extends StatelessWidget {
  final CanvasState canvas;
  final int activeStrokePointCount;
  const _RightHud({required this.canvas, required this.activeStrokePointCount});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      'committed strokes: ${canvas.strokes.length}',
      'active points: $activeStrokePointCount',
      'images: ${canvas.images.length}',
      'avatars: ${canvas.avatarPositions.length}',
      'attach: ${canvas.attachState.name}',
      'tool: ${canvas.selectedTool.name}',
    ];
    return _DebugPill(text: lines.join('\n'));
  }
}

class _DebugPill extends StatelessWidget {
  final String text;
  const _DebugPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.3,
        ),
      ),
    );
  }
}

/// Paints a 2-px dashed rectangle around the available bounds.
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    _drawDashedLine(
      canvas,
      paint,
      Offset.zero,
      Offset(size.width, 0),
      dash,
      gap,
    );
    _drawDashedLine(
      canvas,
      paint,
      Offset(size.width, 0),
      Offset(size.width, size.height),
      dash,
      gap,
    );
    _drawDashedLine(
      canvas,
      paint,
      Offset(size.width, size.height),
      Offset(0, size.height),
      dash,
      gap,
    );
    _drawDashedLine(
      canvas,
      paint,
      Offset(0, size.height),
      Offset.zero,
      dash,
      gap,
    );
  }

  void _drawDashedLine(
    Canvas c,
    Paint paint,
    Offset start,
    Offset end,
    double dash,
    double gap,
  ) {
    final total = (end - start).distance;
    if (total <= 0) return;
    final dir = (end - start) / total;
    var drawn = 0.0;
    while (drawn < total) {
      final segEnd = drawn + dash > total ? total : drawn + dash;
      c.drawLine(start + dir * drawn, start + dir * segEnd, paint);
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
