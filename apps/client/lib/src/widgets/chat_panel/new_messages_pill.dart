// Floating "N new messages" pill shown when new messages arrive below the viewport.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class NewMessagesPill extends StatefulWidget {
  final String text;
  final VoidCallback onTap;

  const NewMessagesPill({super.key, required this.text, required this.onTap});

  @override
  State<NewMessagesPill> createState() => _NewMessagesPillState();
}

class _NewMessagesPillState extends State<NewMessagesPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _entrance,
    curve: Curves.elasticOut,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _entrance,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: EchoSpacing.md,
      right: EchoSpacing.xl,
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          label: 'scroll to new messages',
          button: true,
          child: GestureDetector(
            onTap: widget.onTap,
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.7, end: 1.0).animate(_scale),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EchoSpacing.lg,
                    vertical: EchoSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: context.accent,
                    borderRadius: BorderRadius.circular(EchoRadii.xxl),
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
                        widget.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: EchoSpacing.xs),
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
        ),
      ),
    );
  }
}
