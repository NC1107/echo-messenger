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
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isEditing
            ? context.accent.withValues(alpha: 0.12)
            : context.surface,
        borderRadius: BorderRadius.circular(6),
        border: isEditing
            ? Border.all(color: context.accent.withValues(alpha: 0.4), width: 1)
            : null,
      ),
      child: Row(
        children: [
          if (isEditing)
            Icon(Icons.edit_outlined, size: 12, color: context.accent)
          else
            TypingDots(color: context.textMuted, dotSize: 4),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 12,
                fontStyle: isEditing ? FontStyle.normal : FontStyle.italic,
                color: isEditing ? context.accent : context.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isEditing && onCancelEdit != null)
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
String computeTypingText({
  required List<String> typingUsers,
  required bool isGroup,
  required String displayName,
}) {
  if (!isGroup) return '$displayName is typing...';
  if (typingUsers.length == 1) return '${typingUsers.first} is typing...';
  return '${typingUsers.join(", ")} are typing...';
}
