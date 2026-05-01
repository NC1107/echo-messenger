import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Applies a markdown [prefix] and [suffix] around the current selection in
/// [controller].  If no text is selected, the markers are inserted at the
/// cursor and the cursor is placed between them so the user can start typing.
void applyMarkdownWrap(
  TextEditingController controller, {
  required String prefix,
  required String suffix,
}) {
  final text = controller.text;
  final sel = controller.selection;

  if (!sel.isValid) {
    // No valid selection — append at end.
    final newText = text + prefix + suffix;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: text.length + prefix.length),
    );
    return;
  }

  final start = sel.start;
  final end = sel.end;

  if (start == end) {
    // Collapsed cursor — insert markers and place cursor between them.
    final newText =
        text.substring(0, start) + prefix + suffix + text.substring(start);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + prefix.length),
    );
  } else {
    // Wrap selected text.
    final selected = text.substring(start, end);
    final newText =
        text.substring(0, start) +
        prefix +
        selected +
        suffix +
        text.substring(end);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start + prefix.length + selected.length + suffix.length,
      ),
    );
  }
}

/// Applies a blockquote prefix (`> `) to every selected line (or the current
/// line when nothing is selected).
void applyQuotePrefix(TextEditingController controller) {
  final text = controller.text;
  final sel = controller.selection;

  if (!sel.isValid) return;

  final start = sel.start;
  final end = sel.end;

  // Find the beginning of the first affected line.
  var lineStart = start;
  while (lineStart > 0 && text[lineStart - 1] != '\n') {
    lineStart--;
  }

  final segment = text.substring(lineStart, end);
  final quoted = segment.split('\n').map((l) => '> $l').join('\n');
  final delta = quoted.length - segment.length;
  final newText = text.substring(0, lineStart) + quoted + text.substring(end);

  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: end + delta),
  );
}

/// Compact row of markdown-formatting buttons placed above the composer input.
///
/// Each button either wraps the selected text with its markdown markers or,
/// when nothing is selected, inserts empty markers and places the cursor
/// between them.
class MarkdownToolbar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onLinkTap;

  const MarkdownToolbar({super.key, required this.controller, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.format_bold,
            tooltip: 'Bold',
            semanticsLabel: 'Bold',
            onPressed: () =>
                applyMarkdownWrap(controller, prefix: '**', suffix: '**'),
          ),
          _ToolbarButton(
            icon: Icons.format_italic,
            tooltip: 'Italic',
            semanticsLabel: 'Italic',
            onPressed: () =>
                applyMarkdownWrap(controller, prefix: '*', suffix: '*'),
          ),
          _ToolbarButton(
            icon: Icons.format_strikethrough,
            tooltip: 'Strikethrough',
            semanticsLabel: 'Strikethrough',
            onPressed: () =>
                applyMarkdownWrap(controller, prefix: '~~', suffix: '~~'),
          ),
          _ToolbarButton(
            icon: Icons.code,
            tooltip: 'Inline code',
            semanticsLabel: 'Inline code',
            onPressed: () =>
                applyMarkdownWrap(controller, prefix: '`', suffix: '`'),
          ),
          _ToolbarButton(
            icon: Icons.format_quote,
            tooltip: 'Block quote',
            semanticsLabel: 'Block quote',
            onPressed: () => applyQuotePrefix(controller),
          ),
          _ToolbarButton(
            icon: Icons.link,
            tooltip: 'Insert link',
            semanticsLabel: 'Insert link',
            onPressed: onLinkTap,
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final VoidCallback? onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Use the Echo muted colour when the extension is present (production),
    // fall back to the Material icon colour so the widget renders in plain
    // MaterialApp test harnesses without throwing.
    final iconColor =
        Theme.of(context).extension<EchoColorExtension>()?.textMuted ??
        Theme.of(context).iconTheme.color;
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
