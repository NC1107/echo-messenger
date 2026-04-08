import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Animated three-dot typing indicator with a subtle bounce effect.
class TypingDots extends StatefulWidget {
  final Color? color;
  final double dotSize;

  const TypingDots({super.key, this.color, this.dotSize = 6});

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
      duration: const Duration(milliseconds: 1200),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            // Stagger each dot by 0.2 of the animation cycle
            final offset = (i * 0.2);
            final t = (_controller.value + offset) % 1.0;
            // Bounce: dot moves up during first half, back down during second
            final bounce = math.sin(t * math.pi) * 4.0;
            return Container(
              margin: EdgeInsets.only(
                right: i < 2 ? 3 : 0,
                bottom: bounce.clamp(0, 4),
              ),
              width: widget.dotSize,
              height: widget.dotSize,
              decoration: BoxDecoration(
                color: dotColor.withValues(
                  alpha: 0.4 + 0.6 * math.sin(t * math.pi),
                ),
                shape: BoxShape.circle,
              ),
            );
          },
        );
      }),
    );
  }
}
