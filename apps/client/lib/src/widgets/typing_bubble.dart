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
        color: context.recvBubble,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return _TypingDot(
            controller: _controller,
            color: dotColor,
            size: widget.dotSize,
            index: i,
          );
        }),
      ),
    );
  }
}

/// Single bouncing dot in the typing indicator.
///
/// Extracted as a separate widget so each dot rebuilds independently on
/// animation ticks instead of rebuilding the entire [TypingDots] tree.
class _TypingDot extends StatelessWidget {
  final AnimationController controller;
  final Color color;
  final double size;
  final int index;

  const _TypingDot({
    required this.controller,
    required this.color,
    required this.size,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final offset = index * 0.15;
        final t = (controller.value + offset) % 1.0;
        // Ease-in-out bounce curve with sharper peak
        final curve = Curves.easeInOut.transform(
          t < 0.5 ? t * 2.0 : 2.0 - t * 2.0,
        );
        final bounce = curve * 8.0;
        return Padding(
          padding: EdgeInsets.only(right: index < 2 ? 4 : 0),
          child: Transform.translate(
            offset: Offset(0, -bounce),
            child: SizedBox.square(
              dimension: size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.4 + 0.6 * curve),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
