import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../theme/echo_theme.dart';

/// Displays an autocomplete popup for @-mentioning conversation members.
///
/// Sits above the input bar and filters members based on [mentionQuery].
/// When a row is tapped, [onMentionSelected] fires with the username
/// (or the broadcast keyword `everyone` / `here`).
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

  /// Broadcast pseudo-mentions surfaced alongside member rows. Phase 1
  /// ships `@everyone` and `@here`; role mentions are out of scope (#451).
  static const List<_BroadcastMention> _broadcasts = [
    _BroadcastMention(
      keyword: 'everyone',
      icon: Icons.campaign_outlined,
      subtitle: 'Notify everyone',
    ),
    _BroadcastMention(
      keyword: 'here',
      icon: Icons.bolt_outlined,
      subtitle: 'Notify online members',
    ),
  ];

  List<ConversationMember> get _filteredMembers {
    if (mentionQuery.isEmpty) return members;
    return members
        .where((m) => m.username.toLowerCase().startsWith(mentionQuery))
        .toList();
  }

  List<_BroadcastMention> get _filteredBroadcasts {
    if (mentionQuery.isEmpty) return _broadcasts;
    return _broadcasts
        .where((b) => b.keyword.startsWith(mentionQuery))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final memberRows = _filteredMembers;
    final broadcastRows = _filteredBroadcasts;
    if (memberRows.isEmpty && broadcastRows.isEmpty) {
      return const SizedBox.shrink();
    }

    // ListView uses `reverse: true`, so item 0 paints at the bottom (next
    // to the text field).  Members come first (lower indices) so they sit
    // closest to the cursor; broadcasts get pushed to the top of the
    // picker — they're rarer and visually distinct.
    final total = memberRows.length + broadcastRows.length;

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border.all(color: context.border),
      ),
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.zero,
        itemCount: total,
        itemBuilder: (context, i) {
          if (i < memberRows.length) {
            final member = memberRows[i];
            return _MentionItem(
              member: member,
              onTap: () => onMentionSelected(member.username),
            );
          }
          final broadcast = broadcastRows[i - memberRows.length];
          return _BroadcastMentionItem(
            broadcast: broadcast,
            onTap: () => onMentionSelected(broadcast.keyword),
          );
        },
      ),
    );
  }
}

class _BroadcastMention {
  final String keyword;
  final IconData icon;
  final String subtitle;

  const _BroadcastMention({
    required this.keyword,
    required this.icon,
    required this.subtitle,
  });
}

class _BroadcastMentionItem extends StatelessWidget {
  final _BroadcastMention broadcast;
  final VoidCallback onTap;

  const _BroadcastMentionItem({required this.broadcast, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'mention @${broadcast.keyword}',
      hint: broadcast.subtitle,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(broadcast.icon, size: 14, color: context.accent),
              const SizedBox(width: 8),
              Text(
                '@${broadcast.keyword}',
                style: TextStyle(
                  fontSize: 13,
                  color: context.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  broadcast.subtitle,
                  style: TextStyle(fontSize: 11, color: context.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
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
    return Semantics(
      label: 'mention ${member.username}',
      button: true,
      child: InkWell(
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
