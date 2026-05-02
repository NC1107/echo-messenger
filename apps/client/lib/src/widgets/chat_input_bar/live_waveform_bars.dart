import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Live mini waveform bars that grow as amplitude samples arrive.
/// Scrolls from right to left, showing the most recent [_kDisplayCount] bars.
class LiveWaveformBars extends StatelessWidget {
  static const _kDisplayCount = 40;

  final List<double> amplitudes;

  const LiveWaveformBars({super.key, required this.amplitudes});

  @override
  Widget build(BuildContext context) {
    final bars = amplitudes.length > _kDisplayCount
        ? amplitudes.sublist(amplitudes.length - _kDisplayCount)
        : amplitudes;

    return SizedBox(
      height: 24,
      child: CustomPaint(
        painter: _LiveWaveformPainter(bars: bars, color: EchoTheme.danger),
      ),
    );
  }
}

class _LiveWaveformPainter extends CustomPainter {
  final List<double> bars;
  final Color color;

  const _LiveWaveformPainter({required this.bars, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const barGap = 2.0;
    final count = bars.length;
    final barWidth = (size.width - barGap * (count - 1)) / count;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final h = (bars[i] * size.height).clamp(2.0, size.height);
      final left = i * (barWidth + barGap);
      final top = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          top,
          left + barWidth,
          top + h,
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWaveformPainter old) => old.bars != bars;
}
