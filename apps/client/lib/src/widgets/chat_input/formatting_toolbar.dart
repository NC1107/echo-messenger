import 'package:flutter/material.dart';

import '../input/markdown_toolbar.dart' show applyMarkdownWrap;
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

/// @deprecated No longer used in the UI. The always-visible Aa toggle button
/// has been removed in favour of a context-aware floating popover on desktop
/// (see [SelectionFormattingPopover]) and keyboard-shortcut-only formatting on
/// mobile. This class is kept so existing tests continue to compile; it will be
/// deleted in a follow-up cleanup.
@Deprecated('Use SelectionFormattingPopover on desktop; no toolbar on mobile.')
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

/// A floating popover row of formatting buttons (Bold, Italic, Strikethrough,
/// Inline code) that appears above the text field when the user has an active
/// text selection on desktop/web. Dismissed automatically when the selection
/// collapses.
///
/// Unlike the old always-visible [FormattingToolbar], this widget is mounted
/// only when a selection exists; no [AnimationController] needed for the
/// open/close transition.
class SelectionFormattingPopover extends StatelessWidget {
  final TextEditingController controller;

  /// Provided for API symmetry but not used internally; the popover is
  /// mounted/unmounted by the parent [Stack] based on selection state.
  final AnimationController animationController;

  const SelectionFormattingPopover({
    super.key,
    required this.controller,
    required this.animationController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.extension<EchoColorExtension>();
    final bgColor = color?.surfaceHover ?? theme.colorScheme.surface;
    final borderColor = theme.dividerColor;

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: bgColor,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
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

/// Animated collapsible row of four formatting buttons (Bold, Italic,
/// Strikethrough, Inline code). Kept for internal use by
/// [SelectionFormattingPopover]; public consumers should use that instead.
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
