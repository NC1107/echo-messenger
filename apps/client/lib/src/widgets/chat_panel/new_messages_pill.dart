// Floating "N new messages" pill shown when new messages arrive below the viewport.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class NewMessagesPill extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const NewMessagesPill({super.key, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 12,
      right: 24,
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          label: 'scroll to new messages',
          button: true,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.accent,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_downward,
                    size: 14,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
