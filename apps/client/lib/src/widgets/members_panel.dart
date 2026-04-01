import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../theme/echo_theme.dart';

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
          CircleAvatar(
            radius: 10,
            backgroundColor: _avatarColor(member.username),
            child: Text(
              member.username.isNotEmpty
                  ? member.username[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFFE06666),
      Color(0xFFF6B05C),
      Color(0xFF57D28F),
      Color(0xFF5DADE2),
      Color(0xFFAF7AC5),
      Color(0xFFEB984E),
    ];
    final index = name.hashCode.abs() % colors.length;
    return colors[index];
  }
}
