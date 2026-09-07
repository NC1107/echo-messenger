import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/user_presence_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'confirm_dialog.dart';
import 'member_list_row.dart';

class MembersPanel extends ConsumerWidget {
  final Conversation? conversation;

  /// Called after a leave or delete operation to clear the selected conversation.
  final VoidCallback? onGroupLeft;

  /// Panel width in logical pixels. Defaults to [defaultWidth] (280) to match
  /// the pre-resize behaviour; the home-screen scaffold passes the value the
  /// user has dragged the resize handle to.
  final double width;

  /// Default and bound constants used by the home-screen resize handle so
  /// the width state and the panel render stay in sync.
  static const double defaultWidth = 280;
  static const double minWidth = 220;
  static const double maxWidth = 480;

  const MembersPanel({
    super.key,
    this.conversation,
    this.onGroupLeft,
    this.width = defaultWidth,
  });

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

    // Determine if current user is owner or admin
    final myMember = members.where((m) => m.userId == myUserId).firstOrNull;
    final myRole = myMember?.role;
    final isOwner = myRole == 'owner';
    final canRemove = isOwner || myRole == 'admin';

    // Group by presence (Discord pattern). Self always counts as online —
    // we don't broadcast our own status to ourselves. Role pill stays on
    // the row so owner/admin is still readable; the role split was
    // burying online members below offline ones in large groups.
    int sortByName(ConversationMember a, ConversationMember b) =>
        a.username.toLowerCase().compareTo(b.username.toLowerCase());

    bool isMemberOnline(ConversationMember m) {
      if (m.userId == myUserId) return true;
      return ref.watch(
        userPresenceProvider(m.userId).select((p) => p.isOnline),
      );
    }

    final online = <ConversationMember>[];
    final offline = <ConversationMember>[];
    for (final m in members) {
      (isMemberOnline(m) ? online : offline).add(m);
    }
    online.sort(sortByName);
    offline.sort(sortByName);

    final items = <_MemberListItem>[];
    void addGroup(String headerLabel, List<ConversationMember> roster) {
      if (roster.isEmpty) return;
      items.add(_MemberListItem.header(headerLabel));
      for (final m in roster) {
        items.add(_MemberListItem.member(m));
      }
    }

    addGroup('Online — ${online.length}', online);
    addGroup('Offline — ${offline.length}', offline);

    return Container(
      width: width,
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
              // Chat header already shows "<N> members"; just label the panel here.
              child: Text(
                'Members',
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

  const _MemberListItem._({
    required this.isHeader,
    this.headerLabel,
    this.member,
  });

  factory _MemberListItem.header(String label) =>
      _MemberListItem._(isHeader: true, headerLabel: label);

  factory _MemberListItem.member(ConversationMember m) =>
      _MemberListItem._(isHeader: false, member: m);
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
  bool _isRemoving = false;

  Future<void> _removeMember() async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Remove member',
      content: 'Remove ${widget.member.username} from this group?',
      confirmLabel: 'Remove',
      destructive: true,
    );

    if (!confirmed || !mounted) return;

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

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final canRemove = widget.canRemove && !widget.isMe && !_isRemoving;

    Widget? trailing;
    Widget? hoverTrailing;
    if (_isRemoving) {
      trailing = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.textMuted,
        ),
      );
    } else if (canRemove) {
      hoverTrailing = IconButton(
        icon: const Icon(Icons.close, size: 14),
        color: context.textMuted,
        tooltip: 'Remove member',
        onPressed: _removeMember,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      );
    }

    return MemberListRow(
      member: member,
      isMe: widget.isMe,
      density: MemberRowDensity.compact,
      onTap: () => UserProfileScreen.show(context, ref, member.userId),
      trailing: trailing,
      hoverTrailing: hoverTrailing,
    );
  }
}
