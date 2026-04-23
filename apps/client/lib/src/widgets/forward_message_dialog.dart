import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, avatarColor;

/// Shows a modal dialog that lets the user pick a conversation to forward a
/// message to, then calls [onForward] with the selected conversation.
Future<void> showForwardDialog({
  required BuildContext context,
  required WidgetRef ref,
  required void Function(Conversation target) onForward,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ForwardMessageDialog(onForward: onForward),
  );
}

class _ForwardMessageDialog extends ConsumerStatefulWidget {
  final void Function(Conversation target) onForward;

  const _ForwardMessageDialog({required this.onForward});

  @override
  ConsumerState<_ForwardMessageDialog> createState() =>
      _ForwardMessageDialogState();
}

class _ForwardMessageDialogState extends ConsumerState<_ForwardMessageDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Conversation> _filtered(List<Conversation> all, String myUserId) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((conv) {
      final name = conv.displayName(myUserId).toLowerCase();
      if (name.contains(q)) return true;
      return conv.members.any((m) => m.username.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final convState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';

    final filtered = _filtered(convState.conversations, myUserId);

    return Dialog(
      backgroundColor: context.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Forward Message',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Close forward dialog',
                    button: true,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(
                          Icons.close,
                          size: 20,
                          color: context.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Search field
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search conversations',
                  hintStyle: TextStyle(color: context.textSecondary),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: context.textSecondary,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  filled: true,
                  fillColor: context.surface,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: context.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: context.accent),
                  ),
                ),
                style: TextStyle(color: context.textPrimary, fontSize: 14),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),

            Divider(height: 16, color: context.border),

            // Conversation list
            Expanded(
              child: convState.isLoading
                  ? Center(
                      child: CircularProgressIndicator(color: context.accent),
                    )
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No conversations found',
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 14,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final conv = filtered[i];
                        return _ConversationPickerTile(
                          conversation: conv,
                          myUserId: myUserId,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onForward(conv);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationPickerTile extends StatelessWidget {
  final Conversation conversation;
  final String myUserId;
  final VoidCallback onTap;

  const _ConversationPickerTile({
    required this.conversation,
    required this.myUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName(myUserId);
    final subtitle = conversation.isGroup
        ? '${conversation.members.length} members'
        : conversation.members
              .where((m) => m.userId != myUserId)
              .map((m) => m.username)
              .join(', ');

    return Semantics(
      label: 'Forward to $name',
      button: true,
      child: SizedBox(
        height: 56,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                buildAvatar(name: name, radius: 20, bgColor: avatarColor(name)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (conversation.isGroup)
                  Icon(Icons.group_outlined, size: 16, color: context.textMuted)
                else
                  Icon(
                    Icons.person_outline,
                    size: 16,
                    color: context.textMuted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
