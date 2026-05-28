import 'package:flutter/material.dart';

import '../input/markdown_toolbar.dart' show applyMarkdownWrap;
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

/// An "Aa" toggle button paired with a collapsible row of formatting buttons.
///
/// Layout contract:
///   - [AaToggleButton] is placed left of the input pill (next to attach).
///   - When toggled on, [FormattingToolbar] slides in above the text field.
///   - Each button wraps any active selection with the relevant delimiters.
///     With no selection, empty delimiters are inserted and the cursor is
///     placed between them so the user can type immediately.
///
/// Works with any [TextEditingController]; [MarkdownTextEditingController]
/// renders the delimiters at reduced opacity automatically.
class AaToggleButton extends StatelessWidget {
  final bool active;
  final VoidCallback onToggle;

  const AaToggleButton({
    super.key,
    required this.active,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).extension<EchoColorExtension>();
    final iconColor = active
        ? Theme.of(context).colorScheme.primary
        : (color?.textMuted ?? Theme.of(context).iconTheme.color);

    return Semantics(
      label: 'Toggle formatting toolbar',
      button: true,
      child: Tooltip(
        message: 'Formatting',
        child: SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            icon: const Icon(Icons.text_fields),
            color: iconColor,
            onPressed: onToggle,
          ),
        ),
      ),
    );
  }
}

/// Animated collapsible row of four formatting buttons (Bold, Italic,
/// Strikethrough, Inline code).
///
/// Use [SizeTransition] so the toolbar slides in without layout jumps.
class FormattingToolbar extends StatelessWidget {
  final TextEditingController controller;
  final AnimationController animationController;

  const FormattingToolbar({
    super.key,
    required this.controller,
    required this.animationController,
  });

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: CurvedAnimation(
        parent: animationController,
        curve: MotionCurves.entrance,
      ),
      // ignore: deprecated_member_use
      axisAlignment: -1.0,

      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              _FormatButton(
                icon: Icons.format_bold,
                tooltip: 'Bold (Ctrl+B)',
                semanticsLabel: 'Bold',
                onPressed: () =>
                    applyMarkdownWrap(controller, prefix: '**', suffix: '**'),
              ),
              _FormatButton(
                icon: Icons.format_italic,
                tooltip: 'Italic (Ctrl+I)',
                semanticsLabel: 'Italic',
                onPressed: () =>
                    applyMarkdownWrap(controller, prefix: '*', suffix: '*'),
              ),
              _FormatButton(
                icon: Icons.format_strikethrough,
                tooltip: 'Strikethrough (Ctrl+Shift+X)',
                semanticsLabel: 'Strikethrough',
                onPressed: () =>
                    applyMarkdownWrap(controller, prefix: '~~', suffix: '~~'),
              ),
              _FormatButton(
                icon: Icons.code,
                tooltip: 'Inline code (Ctrl+E)',
                semanticsLabel: 'Inline code',
                onPressed: () =>
                    applyMarkdownWrap(controller, prefix: '`', suffix: '`'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final VoidCallback onPressed;

  const _FormatButton({
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).extension<EchoColorExtension>();
    final iconColor = color?.textMuted ?? Theme.of(context).iconTheme.color;
    return Semantics(
      label: semanticsLabel,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 14,
            icon: Icon(icon),
            color: iconColor,
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
