import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../theme/echo_theme.dart';

/// Displays an autocomplete popup for @-mentioning conversation members.
///
/// Sits above the input bar and filters members based on [mentionQuery].
/// When a member is tapped, [onMentionSelected] fires with their username.
class MentionAutocomplete extends StatelessWidget {
  final List<ConversationMember> members;
  final String mentionQuery;
  final ValueChanged<String> onMentionSelected;

  const MentionAutocomplete({
    super.key,
    required this.members,
    required this.mentionQuery,
    required this.onMentionSelected,
  });

  List<ConversationMember> get _filteredMembers {
    if (mentionQuery.isEmpty) return members;
    return members
        .where((m) => m.username.toLowerCase().startsWith(mentionQuery))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredMembers;
    if (filtered.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border.all(color: context.border),
      ),
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.zero,
        itemCount: filtered.length,
        itemBuilder: (context, i) {
          final member = filtered[i];
          return _MentionItem(
            member: member,
            onTap: () => onMentionSelected(member.username),
          );
        },
      ),
    );
  }
}

class _MentionItem extends StatelessWidget {
  final ConversationMember member;
  final VoidCallback onTap;

  const _MentionItem({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.alternate_email, size: 14, color: context.accent),
            const SizedBox(width: 8),
            Text(
              member.username,
              style: TextStyle(
                fontSize: 13,
                color: context.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (member.role != null) ...[
              const SizedBox(width: 6),
              Text(
                member.role!,
                style: TextStyle(fontSize: 11, color: context.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Attempts to extract a partial mention query from [text] at the given
/// [cursorPosition]. Returns the lowercased query string when an active `@`
/// trigger is found, or `null` when no mention autocomplete should be shown.
String? extractMentionQuery(String text, int cursorPosition) {
  if (cursorPosition < 0 || cursorPosition > text.length) return null;

  final beforeCursor = text.substring(0, cursorPosition);
  final atIndex = beforeCursor.lastIndexOf('@');
  if (atIndex < 0) return null;

  if (atIndex > 0 && beforeCursor[atIndex - 1] != ' ') return null;

  final partial = beforeCursor.substring(atIndex + 1);
  if (partial.contains(' ')) return null;

  return partial.toLowerCase();
}

/// Inserts a completed @mention into [text] at the cursor position, replacing
/// the partial query. Returns the new [TextEditingValue] with updated cursor.
TextEditingValue insertMention({
  required String text,
  required int cursorPosition,
  required String username,
}) {
  if (cursorPosition < 0) return TextEditingValue(text: text);

  final beforeCursor = text.substring(0, cursorPosition);
  final atIndex = beforeCursor.lastIndexOf('@');
  if (atIndex < 0) return TextEditingValue(text: text);

  final afterCursor = text.substring(cursorPosition);
  final replacement = '@$username ';
  final newText = text.substring(0, atIndex) + replacement + afterCursor;
  final newCursorPos = atIndex + replacement.length;

  return TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: newCursorPos),
  );
}
