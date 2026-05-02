// Floating pill at top of the message list that shows the current day while scrolling.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class FloatingDatePill extends StatelessWidget {
  final bool visible;
  final String? date;

  const FloatingDatePill({
    super.key,
    required this.visible,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: context.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.border),
            ),
            child: Text(
              date ?? '',
              style: TextStyle(fontSize: 11, color: context.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}
