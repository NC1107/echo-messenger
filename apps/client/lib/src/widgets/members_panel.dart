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
    final myUserId = ref.watch(authProvider).userId ?? '';
    final onlineUsers = ref.watch(
      websocketProvider.select((s) => s.onlineUsers),
    );

    // Determine if current user is owner or admin
    final myMember = members.where((m) => m.userId == myUserId).firstOrNull;
    final myRole = myMember?.role;
    final isOwner = myRole == 'owner';
    final canRemove = isOwner || myRole == 'admin';

    // Split members into online / offline sections
    final onlineMembers = members
        .where((m) => onlineUsers.contains(m.userId))
        .toList();
    final offlineMembers = members
        .where((m) => !onlineUsers.contains(m.userId))
        .toList();

    // Build flat list items: section header + rows
    final items = <_MemberListItem>[];
    if (onlineMembers.isNotEmpty) {
      items.add(_MemberListItem.header('ONLINE — ${onlineMembers.length}'));
      for (final m in onlineMembers) {
        items.add(_MemberListItem.member(m, isOnline: true));
      }
    }
    if (offlineMembers.isNotEmpty) {
      items.add(_MemberListItem.header('OFFLINE — ${offlineMembers.length}'));
      for (final m in offlineMembers) {
        items.add(_MemberListItem.member(m, isOnline: false));
      }
    }

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
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
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
                );
              },
            ),
          ),
          // Leave group button (non-owners only)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.border, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isOwner)
                  _LeaveGroupButton(
                    conversationId: conv.id,
                    onLeft: onGroupLeft,
                  ),
              ],
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

  const _MemberListItem._({
    required this.isHeader,
    this.headerLabel,
    this.member,
    this.isOnline = false,
  });

  factory _MemberListItem.header(String label) =>
      _MemberListItem._(isHeader: true, headerLabel: label);

  factory _MemberListItem.member(
    ConversationMember m, {
    required bool isOnline,
  }) => _MemberListItem._(isHeader: false, member: m, isOnline: isOnline);
}

class _MemberRow extends ConsumerStatefulWidget {
  final ConversationMember member;
  final String conversationId;
  final bool canRemove;
  final bool isMe;
  final bool isOnline;

  const _MemberRow({
    required this.member,
    required this.conversationId,
    required this.canRemove,
    required this.isMe,
    required this.isOnline,
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
        bgColor = context.accent.withValues(alpha: 0.15);
        textColor = context.accent;
        label = 'Owner';
      case 'admin':
        bgColor = EchoTheme.warning.withValues(alpha: 0.15);
        textColor = EchoTheme.warning;
        label = 'Admin';
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Avatar
                buildAvatar(
                  name: member.username,
                  radius: 14,
                  imageUrl: resolveAvatarUrl(
                    member.avatarUrl,
                    ref.watch(serverUrlProvider),
                  ),
                ),
                const SizedBox(width: 8),
                // Online dot
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.isOnline
                        ? EchoTheme.online
                        : context.textMuted,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.sidebarBg, width: 1.5),
                  ),
                ),
                const SizedBox(width: 8),
                // Username + role icon
                Expanded(
                  child: Row(
                    children: [
                      if (member.role == 'owner') ...[
                        Semantics(
                          label: 'owner',
                          child: Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Colors.amber,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ] else if (member.role == 'admin') ...[
                        Semantics(
                          label: 'admin',
                          child: Icon(
                            Icons.shield_rounded,
                            size: 14,
                            color: Colors.blue,
                          ),
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
                          (member.role == 'owner' || member.role == 'admin'))
                        _buildRoleBadge(member.role!),
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

class _LeaveGroupButton extends ConsumerStatefulWidget {
  final String conversationId;
  final VoidCallback? onLeft;

  const _LeaveGroupButton({required this.conversationId, this.onLeft});

  @override
  ConsumerState<_LeaveGroupButton> createState() => _LeaveGroupButtonState();
}

class _LeaveGroupButtonState extends ConsumerState<_LeaveGroupButton> {
  bool _isLoading = false;

  Future<void> _leaveGroup() async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    setState(() => _isLoading = true);

    try {
      final response = await http
          .post(
            Uri.parse('$serverUrl/api/groups/${widget.conversationId}/leave'),
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        widget.onLeft?.call();
        if (mounted) {
          ToastService.show(context, 'Left group', type: ToastType.success);
        }
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ToastService.show(
            context,
            'Failed to leave group (${response.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ToastService.show(
          context,
          'Failed to leave group',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: OutlinedButton.icon(
        onPressed: _isLoading ? null : _leaveGroup,
        icon: _isLoading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: EchoTheme.danger,
                ),
              )
            : const Icon(Icons.logout, size: 16),
        label: const Text('Leave Group'),
        style: OutlinedButton.styleFrom(
          foregroundColor: EchoTheme.danger,
          side: const BorderSide(color: EchoTheme.danger),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
