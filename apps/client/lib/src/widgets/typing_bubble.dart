import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Animated three-dot typing indicator styled after Apple iMessage.
/// Displays inside a small bubble with bouncing dots.
class TypingDots extends StatefulWidget {
  final Color? color;
  final double dotSize;

  const TypingDots({super.key, this.color, this.dotSize = 8});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = widget.color ?? context.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final offset = i * 0.15;
              final t = (_controller.value + offset) % 1.0;
              // Ease-in-out bounce curve with sharper peak
              final curve = Curves.easeInOut.transform(
                t < 0.5 ? t * 2.0 : 2.0 - t * 2.0,
              );
              final bounce = curve * 8.0;
              return Container(
                margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
                child: Transform.translate(
                  offset: Offset(0, -bounce),
                  child: Container(
                    width: widget.dotSize,
                    height: widget.dotSize,
                    decoration: BoxDecoration(
                      color: dotColor.withValues(alpha: 0.4 + 0.6 * curve),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
