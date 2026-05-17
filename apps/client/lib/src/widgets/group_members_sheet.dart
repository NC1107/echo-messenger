/// Bottom sheet listing members of a group conversation, shown on mobile
/// when the user taps the "people" icon in the chat header.
///
/// On wide / desktop layouts the existing [MembersPanel] sidebar is used
/// instead; this sheet is only shown from [ChatHeaderBar] when the layout
/// is narrow (i.e. [Responsive.isMobile] is true).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, resolveAvatarUrl;
import 'conversation_item.dart' show presenceStatusDotColor;

/// Shows the [GroupMembersSheet] as a modal bottom sheet.
///
/// Call this from the header "people" icon's [onPressed].
void showGroupMembersSheet(BuildContext context, Conversation conversation) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GroupMembersSheet(conversation: conversation),
  );
}

/// A draggable bottom sheet that lists every member of [conversation] with
/// their avatar, name, role badge, and a presence dot.
///
/// Sort order: online first, then alphabetical within each online/offline
/// bucket. Members are read directly from [conversation.members], which is
/// kept up-to-date by [conversationsProvider] (the same data source used by
/// the desktop [MembersPanel]).
class GroupMembersSheet extends ConsumerWidget {
  final Conversation conversation;

  const GroupMembersSheet({super.key, required this.conversation});

  String _memberCountLabel(int count) {
    return '$count member${count == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = conversation;

    final auth = ref.watch(authProvider);
    final myUserId = auth.userId ?? '';
    final myPresenceStatus = auth.presenceStatus;
    final onlineUsers = ref.watch(
      websocketProvider.select((s) => s.onlineUsers),
    );
    final presenceStatuses = ref.watch(
      websocketProvider.select((s) => s.presenceStatuses),
    );

    final members = conv.members;

    // Resolve online/status for each member (mirrors MembersPanel logic).
    ({bool isOnline, String status}) presenceFor(ConversationMember m) {
      if (m.userId == myUserId) {
        return (isOnline: true, status: myPresenceStatus);
      }
      final online = onlineUsers.contains(m.userId);
      final status = presenceStatuses[m.userId] ?? 'online';
      return (isOnline: online, status: status);
    }

    // Sort: online first, then alphabetical within each bucket.
    final sorted = [...members]
      ..sort((a, b) {
        final pa = presenceFor(a);
        final pb = presenceFor(b);
        if (pa.isOnline != pb.isOnline) {
          return pa.isOnline ? -1 : 1;
        }
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      });

    final onlineCount = sorted.where((m) => presenceFor(m).isOnline).length;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(top: BorderSide(color: context.border, width: 1)),
          ),
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.textMuted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      'Members',
                      style: GoogleFonts.inter(
                        color: context.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      onlineCount > 0
                          ? '${members.length} total · $onlineCount online'
                          : _memberCountLabel(members.length),
                      style: GoogleFonts.inter(
                        color: context.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: context.border, height: 1),
              // Member list
              Expanded(
                child: members.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: sorted.length,
                        itemBuilder: (context, index) {
                          final member = sorted[index];
                          final presence = presenceFor(member);
                          return _MobilesMemberRow(
                            member: member,
                            isOnline: presence.isOnline,
                            presenceStatus: presence.status,
                            isMe: member.userId == myUserId,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MobilesMemberRow extends ConsumerWidget {
  final ConversationMember member;
  final bool isOnline;
  final String presenceStatus;
  final bool isMe;

  const _MobilesMemberRow({
    required this.member,
    required this.isOnline,
    required this.presenceStatus,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.watch(serverUrlProvider);

    return Semantics(
      label: 'member: ${member.username}',
      button: true,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          UserProfileScreen.show(context, ref, member.userId);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              // Avatar with presence dot overlay
              Stack(
                children: [
                  buildAvatar(
                    name: member.username,
                    radius: 18,
                    imageUrl: resolveAvatarUrl(member.avatarUrl, serverUrl),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: presenceStatusDotColor(
                          context,
                          presenceStatus,
                          isOnline,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: context.surface, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              // Name + role badge
              Expanded(
                child: Row(
                  children: [
                    if (member.role == 'owner') ...[
                      const Icon(
                        Icons.star_rounded,
                        size: 14,
                        color: Colors.amber,
                        semanticLabel: 'owner',
                      ),
                      const SizedBox(width: 4),
                    ] else if (member.role == 'admin') ...[
                      const Icon(
                        Icons.shield_rounded,
                        size: 14,
                        color: Colors.blue,
                        semanticLabel: 'admin',
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        member.username,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          color: context.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Text(
                        '(you)',
                        style: GoogleFonts.inter(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Role badge chip
              if (member.role == 'owner' || member.role == 'admin')
                _roleBadge(context, member.role!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleBadge(BuildContext context, String role) {
    final Color bgColor;
    final Color textColor;
    final String label;

    if (role == 'owner') {
      bgColor = EchoTheme.warning.withValues(alpha: 0.15);
      textColor = EchoTheme.warning;
      label = 'Owner';
    } else {
      bgColor = context.accent.withValues(alpha: 0.15);
      textColor = context.accentHover;
      label = 'Admin';
    }

    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
