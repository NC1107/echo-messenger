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
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import '../utils/presence.dart';
import 'user_avatar.dart';

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
class GroupMembersSheet extends ConsumerStatefulWidget {
  final Conversation conversation;

  const GroupMembersSheet({super.key, required this.conversation});

  @override
  ConsumerState<GroupMembersSheet> createState() => _GroupMembersSheetState();
}

class _GroupMembersSheetState extends ConsumerState<GroupMembersSheet> {
  static const double _maxChildSize = 0.92;
  final _sheetController = DraggableScrollableController();
  double _currentSize = 0.6;

  String _memberCountLabel(int count) {
    return '$count member${count == 1 ? '' : 's'}';
  }

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_onSheetSizeChanged);
  }

  void _onSheetSizeChanged() {
    if (!_sheetController.isAttached) return;
    final size = _sheetController.size;
    if ((size - _currentSize).abs() > 0.01) {
      setState(() => _currentSize = size);
    }
  }

  @override
  void dispose() {
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;

    final auth = ref.watch(authProvider);
    final myUserId = auth.userId ?? '';
    final myPresenceStatus = auth.presenceStatus;
    final ws = ref.watch(websocketProvider);

    final members = conv.members;

    // Resolve online/status for each member: self is never broadcast by
    // the WS, so substitute auth's local status. Everyone else uses the
    // central presenceFor lookup.
    UserPresence presenceFor(ConversationMember m) {
      if (m.userId == myUserId) {
        return UserPresence(status: myPresenceStatus, isOnline: true);
      }
      return ws.presenceFor(m.userId);
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
    final showExpandHint = _currentSize < _maxChildSize * 0.7;

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: _maxChildSize,
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
              // Drag handle + optional expand hint
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.textMuted.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    if (showExpandHint) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Swipe up for full list',
                        style: GoogleFonts.inter(
                          color: context.textMuted.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
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
                          return _MobilesMemberRow(
                            member: member,
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
  final bool isMe;

  const _MobilesMemberRow({required this.member, required this.isMe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              // Outer InkWell already pops + opens profile, so the avatar
              // itself shouldn't fight that tap target.
              UserAvatar(
                userId: member.userId,
                username: member.username,
                avatarUrl: member.avatarUrl,
                radius: 18,
                showPresence: true,
                openProfileOnTap: false,
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
