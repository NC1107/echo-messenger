import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../theme/echo_theme.dart';
import '../member_role.dart';

/// Displays an autocomplete popup for @-mentioning conversation members.
///
/// Sits above the input bar and filters members based on [mentionQuery].
/// When a row is tapped, [onMentionSelected] fires with the username
/// (or the broadcast keyword `everyone` / `here`).
class MentionAutocomplete extends StatelessWidget {
  final List<ConversationMember> members;
  final String mentionQuery;
  final ValueChanged<String> onMentionSelected;

  /// Index into the visible candidate list (members + broadcasts) that
  /// should render with the selected-row highlight. Driven by the parent
  /// composer's arrow-key navigation. Clamped internally so out-of-range
  /// values render as "no row selected".
  final int selectedIndex;

  const MentionAutocomplete({
    super.key,
    required this.members,
    required this.mentionQuery,
    required this.onMentionSelected,
    this.selectedIndex = 0,
  });

  /// Computes the candidate list the picker would render for [members]
  /// and [mentionQuery]. Same ordering as the rendered ListView:
  /// member rows first (closer to composer), broadcasts last.
  /// Returns the *display* order (members 0..N, broadcasts N..M).
  static List<String> candidateValues(
    List<ConversationMember> members,
    String mentionQuery,
  ) {
    final memberRows = mentionQuery.isEmpty
        ? members
        : members
              .where((m) => m.username.toLowerCase().startsWith(mentionQuery))
              .toList();
    final broadcastRows = mentionQuery.isEmpty
        ? const ['everyone', 'here']
        : const [
            'everyone',
            'here',
          ].where((b) => b.startsWith(mentionQuery.toLowerCase())).toList();
    return [...memberRows.map((m) => m.username), ...broadcastRows];
  }

  /// Broadcast keywords (`@everyone`, `@here`) surfaced alongside member rows.
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
    // Defensive lowercase for future callers; extractMentionQuery already normalises.
    final q = mentionQuery.toLowerCase();
    return _broadcasts.where((b) => b.keyword.startsWith(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final memberRows = _filteredMembers;
    final broadcastRows = _filteredBroadcasts;
    if (memberRows.isEmpty && broadcastRows.isEmpty) {
      return const SizedBox.shrink();
    }

    // ListView is reverse:true — members first so they sit next to the cursor; broadcasts to the top.
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
          final isSelected = i == selectedIndex;
          if (i < memberRows.length) {
            final member = memberRows[i];
            return _MentionItem(
              member: member,
              selected: isSelected,
              onTap: () => onMentionSelected(member.username),
            );
          }
          final broadcast = broadcastRows[i - memberRows.length];
          return _BroadcastMentionItem(
            broadcast: broadcast,
            selected: isSelected,
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
  final bool selected;

  const _BroadcastMentionItem({
    required this.broadcast,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'mention @${broadcast.keyword}',
      hint: broadcast.subtitle,
      button: true,
      selected: selected,
      child: Container(
        color: selected ? context.accentLight : null,
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
      ),
    );
  }
}

class _MentionItem extends StatelessWidget {
  final ConversationMember member;
  final VoidCallback onTap;
  final bool selected;

  const _MentionItem({
    required this.member,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'mention ${member.username}',
      button: true,
      selected: selected,
      child: Container(
        color: selected ? context.accentLight : null,
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
                if (member.role == 'owner' || member.role == 'admin') ...[
                  const SizedBox(width: 4),
                  MemberRoleIcon(role: member.role, size: 12),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
