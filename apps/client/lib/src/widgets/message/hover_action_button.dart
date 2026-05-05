import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Tight 28×28 visual chip with a 44×44 hit target — used for the
/// Discord/Slack-style hover-action bar that sits on top of every message
/// (reply, pin, react, save, delete, ...).
///
/// Pulled out of `message_item.dart` so callers other than the bar itself
/// (notably the action sheet on long-press for mobile) can share the same
/// look and a11y contract instead of re-implementing it.
class HoverActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const HoverActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // 44×44 hit target per WCAG 2.5.5 — keyboard, switch, and assistive
    // pointer users can land on the button even though the visual chip
    // remains a tight 28×28 to preserve the Discord/Slack-style hover bar.
    return Semantics(
      label: tooltip,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 44,
          height: 44,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                  child: Opacity(
                    opacity: 0.75,
                    child: Icon(icon, size: 14, color: context.textSecondary),
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
