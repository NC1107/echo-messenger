import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import 'conversation_panel.dart' show buildAvatar;

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
      return Container(width: 280, color: EchoTheme.sidebarBg);
    }

    final members = conv.members;
    final myUserId = ref.watch(authProvider).userId ?? '';

    // Determine if current user is owner or admin
    final myMember = members.where((m) => m.userId == myUserId).firstOrNull;
    final myRole = myMember?.role;
    final isOwner = myRole == 'owner';
    final canRemove = isOwner || myRole == 'admin';

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
                return _MemberRow(
                  member: member,
                  conversationId: conv.id,
                  canRemove: canRemove && member.role != 'owner',
                  isMe: member.userId == myUserId,
                );
              },
            ),
          ),
          // Leave / Delete group buttons
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isOwner)
                  _DeleteGroupButton(
                    conversationId: conv.id,
                    onDeleted: onGroupLeft,
                  )
                else
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

class _MemberRow extends ConsumerStatefulWidget {
  final ConversationMember member;
  final String conversationId;
  final bool canRemove;
  final bool isMe;

  const _MemberRow({
    required this.member,
    required this.conversationId,
    required this.canRemove,
    required this.isMe,
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
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
        ),
        title: const Text(
          'Remove member',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Remove ${widget.member.username} from this group?',
          style: const TextStyle(color: EchoTheme.textSecondary, fontSize: 14),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${widget.member.username} removed from group'),
            ),
          );
        }
      } else {
        setState(() => _isRemoving = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to remove member (${response.statusCode})'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRemoving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to remove member')),
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
        bgColor = EchoTheme.accent.withValues(alpha: 0.15);
        textColor = EchoTheme.accent;
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

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
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
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      member.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: EchoTheme.textSecondary,
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
                width: 24,
                height: 24,
                child: IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  color: EchoTheme.textMuted,
                  tooltip: 'Remove member',
                  onPressed: _removeMember,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                ),
              ),
            if (_isRemoving)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: EchoTheme.textMuted,
                ),
              ),
          ],
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Left group')));
        }
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to leave group (${response.statusCode})'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to leave group')));
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

class _DeleteGroupButton extends ConsumerStatefulWidget {
  final String conversationId;
  final VoidCallback? onDeleted;

  const _DeleteGroupButton({required this.conversationId, this.onDeleted});

  @override
  ConsumerState<_DeleteGroupButton> createState() => _DeleteGroupButtonState();
}

class _DeleteGroupButtonState extends ConsumerState<_DeleteGroupButton> {
  bool _isLoading = false;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
        ),
        title: const Text(
          'Delete group',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Text(
          'This will permanently delete the group and all its messages. '
          'This action cannot be undone.',
          style: TextStyle(color: EchoTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    setState(() => _isLoading = true);

    try {
      final response = await http
          .delete(
            Uri.parse('$serverUrl/api/groups/${widget.conversationId}'),
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        widget.onDeleted?.call();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Group deleted')));
        }
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete group (${response.statusCode})'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to delete group')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: FilledButton.icon(
        onPressed: _isLoading ? null : _confirmAndDelete,
        icon: _isLoading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.delete_outline, size: 16),
        label: const Text('Delete Group'),
        style: FilledButton.styleFrom(
          backgroundColor: EchoTheme.danger,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
