import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Animated vertex mesh network background for the voice lounge.
///
/// Renders floating dots connected by lines when near each other.
/// Colors are theme-matched using the provided [accentColor].
class VertexMeshBackground extends StatefulWidget {
  final Color accentColor;
  final Color backgroundColor;
  final int vertexCount;
  final double connectionDistance;

  const VertexMeshBackground({
    super.key,
    required this.accentColor,
    required this.backgroundColor,
    this.vertexCount = 40,
    this.connectionDistance = 120,
  });

  @override
  State<VertexMeshBackground> createState() => _VertexMeshBackgroundState();
}

class _VertexMeshBackgroundState extends State<VertexMeshBackground>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final List<_Vertex> _vertices = [];
  Size _lastSize = Size.zero;
  final Random _rng = Random();
  Offset _pointerOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _initVertices(Size size) {
    _vertices.clear();
    for (int i = 0; i < widget.vertexCount; i++) {
      _vertices.add(
        _Vertex(
          x: _rng.nextDouble() * size.width,
          y: _rng.nextDouble() * size.height,
          vx: (_rng.nextDouble() - 0.5) * 0.4,
          vy: (_rng.nextDouble() - 0.5) * 0.4,
          radius: 1.5 + _rng.nextDouble() * 1.5,
        ),
      );
    }
  }

  void _onTick(Duration elapsed) {
    if (_lastSize == Size.zero || _vertices.isEmpty) return;

    final w = _lastSize.width;
    final h = _lastSize.height;

    for (final v in _vertices) {
      v.x += v.vx;
      v.y += v.vy;

      // Bounce off edges
      if (v.x < 0) {
        v.x = 0;
        v.vx = v.vx.abs();
      } else if (v.x > w) {
        v.x = w;
        v.vx = -v.vx.abs();
      }
      if (v.y < 0) {
        v.y = 0;
        v.vy = v.vy.abs();
      } else if (v.y > h) {
        v.y = h;
        v.vy = -v.vy.abs();
      }
    }

    // Trigger repaint via setState — CustomPainter uses the vertex list directly
    setState(() {});
  }

  void _onPointerMove(PointerEvent event) {
    _pointerOffset = event.localPosition;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _lastSize && size.width > 0 && size.height > 0) {
          _lastSize = size;
          if (_vertices.isEmpty) {
            _initVertices(size);
          }
        }

        return MouseRegion(
          onHover: _onPointerMove,
          child: RepaintBoundary(
            child: CustomPaint(
              isComplex: true,
              willChange: true,
              size: size,
              painter: _VertexMeshPainter(
                vertices: _vertices,
                accentColor: widget.accentColor,
                connectionDistance: widget.connectionDistance,
                pointerOffset: _pointerOffset,
                canvasSize: size,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Vertex {
  double x;
  double y;
  double vx;
  double vy;
  double radius;

  _Vertex({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.radius,
  });
}

class _VertexMeshPainter extends CustomPainter {
  final List<_Vertex> vertices;
  final Color accentColor;
  final double connectionDistance;
  final Offset pointerOffset;
  final Size canvasSize;

  _VertexMeshPainter({
    required this.vertices,
    required this.accentColor,
    required this.connectionDistance,
    required this.pointerOffset,
    required this.canvasSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;

    final linePaint = Paint()
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()..style = PaintingStyle.fill;

    final distSq = connectionDistance * connectionDistance;

    // Parallax shift: subtle offset based on pointer position relative to center
    final cx = canvasSize.width / 2;
    final cy = canvasSize.height / 2;
    final parallaxX = (pointerOffset.dx - cx) / cx * 6; // max ±6px shift
    final parallaxY = (pointerOffset.dy - cy) / cy * 6;

    // Draw connections
    for (int i = 0; i < vertices.length; i++) {
      final a = vertices[i];
      final ax = a.x + parallaxX * (a.radius / 3);
      final ay = a.y + parallaxY * (a.radius / 3);

      for (int j = i + 1; j < vertices.length; j++) {
        final b = vertices[j];
        final bx = b.x + parallaxX * (b.radius / 3);
        final by = b.y + parallaxY * (b.radius / 3);

        final dx = ax - bx;
        final dy = ay - by;
        final d2 = dx * dx + dy * dy;

        if (d2 < distSq) {
          final proximity = 1.0 - sqrt(d2) / connectionDistance;
          linePaint.color = accentColor.withValues(alpha: proximity * 0.15);
          canvas.drawLine(Offset(ax, ay), Offset(bx, by), linePaint);
        }
      }
    }

    // Draw dots
    for (final v in vertices) {
      final vx = v.x + parallaxX * (v.radius / 3);
      final vy = v.y + parallaxY * (v.radius / 3);
      dotPaint.color = accentColor.withValues(alpha: 0.4);
      canvas.drawCircle(Offset(vx, vy), v.radius, dotPaint);
    }

    // Draw a subtle glow around pointer position
    if (pointerOffset != Offset.zero) {
      final pointerGlow = Paint()
        ..shader = RadialGradient(
          colors: [
            accentColor.withValues(alpha: 0.08),
            accentColor.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: pointerOffset, radius: 100));
      canvas.drawCircle(pointerOffset, 100, pointerGlow);
    }
  }

  @override
  bool shouldRepaint(covariant _VertexMeshPainter oldDelegate) => true;
}
