import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Emoji / GIF toggle button on the right side of the input pill.
///
/// Switches between keyboard and emoji-picker icons depending on
/// [showMediaPicker]. The parent supplies [onToggle] to flip the
/// appropriate state based on the current layout.
class MediaPickerToggle extends StatelessWidget {
  final bool showMediaPicker;
  final VoidCallback onToggle;

  const MediaPickerToggle({
    super.key,
    required this.showMediaPicker,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: showMediaPicker,
      label: 'Emoji picker',
      child: IconButton(
        icon: Icon(
          showMediaPicker
              ? Icons.keyboard_outlined
              : Icons.sentiment_satisfied_alt_outlined,
          size: 20,
          color: showMediaPicker ? context.accent : context.textSecondary,
        ),
        tooltip: showMediaPicker ? 'Keyboard' : 'Emoji & GIF',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: onToggle,
      ),
    );
  }
}
