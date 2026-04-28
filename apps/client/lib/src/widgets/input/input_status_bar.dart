import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import '../typing_bubble.dart';

/// Shows an editing indicator or typing indicator above the input field.
///
/// When [isEditing] is true, the bar is styled with accent colors and shows a
/// dismiss button. Otherwise it shows a typing indicator with muted styling.
class InputStatusBar extends StatelessWidget {
  final bool isEditing;
  final String statusText;
  final VoidCallback? onCancelEdit;

  const InputStatusBar({
    super.key,
    required this.isEditing,
    required this.statusText,
    this.onCancelEdit,
  });

  @override
  Widget build(BuildContext context) {
    if (isEditing) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: context.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: context.accent.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.edit_outlined, size: 12, color: context.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                statusText,
                style: TextStyle(fontSize: 12, color: context.accent),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onCancelEdit != null)
              Semantics(
                label: 'cancel edit',
                button: true,
                child: GestureDetector(
                  onTap: onCancelEdit,
                  child: Icon(Icons.close, size: 14, color: context.textMuted),
                ),
              ),
          ],
        ),
      );
    }

    // Typing state — small bubble with dots, label sits beside it,
    // not wrapped in a wide tinted container.
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        children: [
          TypingDots(color: context.textMuted, dotSize: 5),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusText,
              style: TextStyle(fontSize: 11, color: context.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Computes the status text to display in the [InputStatusBar].
String computeInputStatusText({
  required bool isEditing,
  required String typingText,
  required bool hasTypingUsers,
}) {
  if (isEditing && hasTypingUsers) {
    return 'Editing message \u2022 $typingText';
  }
  if (isEditing) return 'Editing message...';
  return typingText;
}

/// Computes the typing indicator text from the list of typing users.
///
/// Phrasing scales gracefully past 2 names:
/// - 1 user:   "Alice is typing"
/// - 2 users:  "Alice and Bob are typing"
/// - 3+ users: "Alice, Bob, and 2 others are typing"
String computeTypingText({
  required List<String> typingUsers,
  required bool isGroup,
  required String displayName,
}) {
  if (!isGroup) return '$displayName is typing';
  switch (typingUsers.length) {
    case 0:
      return '';
    case 1:
      return '${typingUsers[0]} is typing';
    case 2:
      return '${typingUsers[0]} and ${typingUsers[1]} are typing';
    default:
      // Show the first two names + "and N others" so the line stays readable
      // even when a whole channel starts typing at once.
      final others = typingUsers.length - 2;
      return '${typingUsers[0]}, ${typingUsers[1]}, '
          'and $others ${others == 1 ? 'other' : 'others'} are typing';
  }
}
