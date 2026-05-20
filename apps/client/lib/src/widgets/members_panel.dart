import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, resolveAvatarUrl;
import 'conversation_item.dart' show presenceStatusDotColor;

class MembersPanel extends ConsumerWidget {
  final Conversation? conversation;

  /// Called after a leave or delete operation to clear the selected conversation.
  final VoidCallback? onGroupLeft;

  const MembersPanel({super.key, this.conversation, this.onGroupLeft});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = conversation;
    // Show nothing for DMs or when no group is selected
    if (conv == null || !conv.isGroup) {
      return const SizedBox.shrink();
    }

    final members = conv.members;
    final auth = ref.watch(authProvider);
    final myUserId = auth.userId ?? '';
    final myPresenceStatus = auth.presenceStatus;
    final onlineUsers = ref.watch(
      websocketProvider.select((s) => s.onlineUsers),
    );
    final presenceStatuses = ref.watch(
      websocketProvider.select((s) => s.presenceStatuses),
    );

    // Resolve presence for any member: self is always online (server doesn't
    // broadcast presence to self); others come from the WS-tracked maps.
    ({bool isOnline, String status}) presenceFor(ConversationMember m) {
      if (m.userId == myUserId) {
        return (isOnline: true, status: myPresenceStatus);
      }
      final online = onlineUsers.contains(m.userId);
      final status = presenceStatuses[m.userId] ?? 'online';
      return (isOnline: online, status: status);
    }

    // Determine if current user is owner or admin
    final myMember = members.where((m) => m.userId == myUserId).firstOrNull;
    final myRole = myMember?.role;
    final isOwner = myRole == 'owner';
    final canRemove = isOwner || myRole == 'admin';

    // Slice 7: group members by role (OWNER / ADMIN / MEMBERS) instead of
    // online/offline. Online presence is still surfaced as a subtle dot
    // and "online"/"away" activity line within each row.
    int sortByName(ConversationMember a, ConversationMember b) =>
        a.username.toLowerCase().compareTo(b.username.toLowerCase());

    final owners = members.where((m) => m.role == 'owner').toList()
      ..sort(sortByName);
    final admins = members.where((m) => m.role == 'admin').toList()
      ..sort(sortByName);
    final regulars =
        members.where((m) => m.role != 'owner' && m.role != 'admin').toList()
          ..sort(sortByName);

    final items = <_MemberListItem>[];
    void addGroup(String headerLabel, List<ConversationMember> roster) {
      if (roster.isEmpty) return;
      items.add(_MemberListItem.header(headerLabel));
      for (final m in roster) {
        final p = presenceFor(m);
        items.add(
          _MemberListItem.member(m, isOnline: p.isOnline, status: p.status),
        );
      }
    }

    addGroup('Owner · ${owners.length}', owners);
    addGroup('Admins · ${admins.length}', admins);
    addGroup('Members · ${regulars.length}', regulars);

    return Container(
      width: 280,
      color: context.sidebarBg,
      child: Column(
        children: [
          // Header
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${members.length} ${members.length == 1 ? 'member' : 'members'}',
                style: TextStyle(
                  color: context.textPrimary,
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
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                if (item.isHeader) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      item.headerLabel!,
                      style: TextStyle(
                        color: context.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  );
                }
                final member = item.member!;
                return _MemberRow(
                  member: member,
                  conversationId: conv.id,
                  canRemove: canRemove && member.role != 'owner',
                  isMe: member.userId == myUserId,
                  isOnline: item.isOnline,
                  presenceStatus: item.status,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Simple discriminated-union item for the flat member list.
class _MemberListItem {
  final bool isHeader;
  final String? headerLabel;
  final ConversationMember? member;
  final bool isOnline;
  final String status;

  const _MemberListItem._({
    required this.isHeader,
    this.headerLabel,
    this.member,
    this.isOnline = false,
    this.status = 'offline',
  });

  factory _MemberListItem.header(String label) =>
      _MemberListItem._(isHeader: true, headerLabel: label);

  factory _MemberListItem.member(
    ConversationMember m, {
    required bool isOnline,
    required String status,
  }) => _MemberListItem._(
    isHeader: false,
    member: m,
    isOnline: isOnline,
    status: status,
  );
}

/// Map a presence status to the activity-line label shown under the username.
String _presenceLabel(String status, bool isOnline) {
  if (!isOnline || status == 'invisible') return 'offline';
  return switch (status) {
    'online' => 'online',
    'away' => 'away',
    'dnd' => 'do not disturb',
    _ => 'online',
  };
}

class _MemberRow extends ConsumerStatefulWidget {
  final ConversationMember member;
  final String conversationId;
  final bool canRemove;
  final bool isMe;
  final bool isOnline;
  final String presenceStatus;

  const _MemberRow({
    required this.member,
    required this.conversationId,
    required this.canRemove,
    required this.isMe,
    required this.isOnline,
    required this.presenceStatus,
  });

  @override
  ConsumerState<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends ConsumerState<_MemberRow> {
  bool _isHovered = false;
  bool _isRemoving = false;

  Future<void> _removeMember() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Remove member',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Remove ${widget.member.username} from this group?',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isRemoving = true);

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    try {
      final response = await http
          .delete(
            Uri.parse(
              '$serverUrl/api/groups/${widget.conversationId}/members/${widget.member.userId}',
            ),
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          ToastService.show(
            context,
            '${widget.member.username} removed from group',
            type: ToastType.success,
          );
        }
      } else {
        setState(() => _isRemoving = false);
        if (mounted) {
          ToastService.show(
            context,
            'Failed to remove member (${response.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRemoving = false);
        ToastService.show(
          context,
          'Failed to remove member',
          type: ToastType.error,
        );
      }
    }
  }

  Widget _buildRoleBadge(String role) {
    final Color bgColor;
    final Color textColor;
    final String label;

    switch (role) {
      case 'owner':
        // Reserve amber (EchoTheme.warning) for actual warnings —
        // "Experimental" feature pill, away presence, etc. Owner is a
        // positive role attribute, so use a brighter accent variant so
        // it still distinguishes from Admin (same accent at lower alpha)
        // without leaning on the warning palette.
        bgColor = EchoTheme.accentHover.withValues(alpha: 0.22);
        textColor = EchoTheme.accentHover;
        label = 'Owner';
      case 'admin':
        bgColor = context.accent.withValues(alpha: 0.15);
        textColor = context.accentHover;
        label = 'Admin';
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final showRemove =
        widget.canRemove && !widget.isMe && _isHovered && !_isRemoving;

    return Semantics(
      label: 'member: ${member.username}',
      button: true,
      child: GestureDetector(
        onTap: () {
          UserProfileScreen.show(context, ref, member.userId);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Container(
            // Slice 7: a touch taller so the activity line under each name
            // fits without crowding the avatar.
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Avatar with presence dot overlaid (matches conversation list
                // pattern in conversation_item.dart — #403).
                Stack(
                  children: [
                    buildAvatar(
                      name: member.username,
                      radius: 14,
                      imageUrl: resolveAvatarUrl(
                        member.avatarUrl,
                        ref.watch(serverUrlProvider),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: presenceStatusDotColor(
                            context,
                            widget.presenceStatus,
                            widget.isOnline,
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: context.sidebarBg,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                // Username + role icon + activity line (slice 7).
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
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
                              style: TextStyle(
                                color: context.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          if (member.role != null &&
                              (member.role == 'owner' ||
                                  member.role == 'admin'))
                            _buildRoleBadge(member.role!),
                        ],
                      ),
                      Text(
                        _presenceLabel(widget.presenceStatus, widget.isOnline),
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                // Remove button
                if (showRemove)
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      color: context.textMuted,
                      tooltip: 'Remove member',
                      onPressed: _removeMember,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                    ),
                  ),
                if (_isRemoving)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.textMuted,
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
