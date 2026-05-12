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
              // Solid surface (was translucent) + thin border + soft shadow
              // for legibility while scrolling fast (design canvas).
              color: context.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.border, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
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
