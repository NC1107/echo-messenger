import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../theme/echo_theme.dart';
import 'conversation_panel.dart' show buildAvatar;

class MembersPanel extends StatelessWidget {
  final Conversation? conversation;

  const MembersPanel({super.key, this.conversation});

  @override
  Widget build(BuildContext context) {
    final conv = conversation;
    // Show nothing for DMs or when no group is selected
    if (conv == null || !conv.isGroup) {
      return Container(width: 280, color: EchoTheme.sidebarBg);
    }

    final members = conv.members;

    return Container(
      width: 280,
      color: EchoTheme.sidebarBg,
      child: Column(
        children: [
          // Header
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Members (${members.length})',
                style: const TextStyle(
                  color: EchoTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          // Member list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: members.length,
              itemBuilder: (context, index) {
                final member = members[index];
                return _MemberRow(member: member);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final ConversationMember member;

  const _MemberRow({required this.member});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Avatar
          buildAvatar(name: member.username, radius: 10),
          const SizedBox(width: 8),
          // Online dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: EchoTheme.online,
              shape: BoxShape.circle,
              border: Border.all(color: EchoTheme.sidebarBg, width: 1.5),
            ),
          ),
          const SizedBox(width: 8),
          // Username
          Expanded(
            child: Text(
              member.username,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: EchoTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
