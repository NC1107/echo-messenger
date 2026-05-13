import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Tight 21×21 visual chip with a 33×33 hit target (75% of the original
/// 28/44 sizes) — used for the Discord/Slack-style hover-action bar that
/// sits on top of every message (reply, pin, react, save, delete, ...).
///
/// Pulled out of `message_item.dart` so callers other than the bar itself
/// (notably the action sheet on long-press for mobile) can share the same
/// look and a11y contract instead of re-implementing it.
class HoverActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final double iconOpacity;
  final Color? iconColor;
  final double cornerRadius;

  const HoverActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 33,
    this.iconSize = 11,
    this.iconOpacity = 0.75,
    this.iconColor,
    this.cornerRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    // 33×33 hit target (scaled down from 44×44 per slice 4) — still
    // comfortably above the 24px Material minimum for hit testing on
    // desktop, while keeping the visual bar dense like Discord/Slack.
    return Semantics(
      label: tooltip,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: size,
          height: size,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(cornerRadius),
            child: Center(
              child: SizedBox(
                width: iconSize + 10,
                height: iconSize + 10,
                child: Center(
                  child: Opacity(
                    opacity: iconOpacity,
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: iconColor ?? context.textSecondary,
                    ),
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
