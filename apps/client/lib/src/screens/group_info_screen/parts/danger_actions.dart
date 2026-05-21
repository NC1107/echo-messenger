// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Leave-group / delete-group flows and the bottom action-button strip
/// (invite link, leave, danger zone with delete).
extension _DangerActions on _GroupInfoScreenState {
  Future<void> _deleteGroup() async {
    final groupName = _conversation?.name ?? 'this group';
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Delete Group',
      content:
          'Are you sure you want to delete "$groupName"? '
          'This will permanently remove all messages and members. '
          'This action cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.delete(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          Navigator.pop(context);
          ToastService.show(context, 'Group deleted', type: ToastType.success);
        }
      } else if (mounted) {
        ToastService.show(
          context,
          'Only the group owner can delete this group',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _deleteGroup failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to delete group',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Leave Group',
      content: 'Are you sure you want to leave this group?',
      confirmLabel: 'Leave',
      destructive: true,
    );

    if (!confirmed) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}/leave'),
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
      );

      if ((response.statusCode == 200 || response.statusCode == 204) &&
          mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) context.go('/home');
      }
    } catch (e) {
      debugPrint('[GroupInfo] _leaveGroup failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to leave group',
          type: ToastType.error,
        );
      }
    }
  }

  List<Widget> _buildActionButtons({required String myRole}) {
    return [
      const Divider(),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: _isGeneratingInvite ? null : _generateAndCopyInviteLink,
          icon: _isGeneratingInvite
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link_outlined),
          label: const Text('Copy Invite Link'),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: _leaveGroup,
          icon: const Icon(Icons.logout_outlined),
          label: const Text('Leave Group'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
      if (myRole == 'owner') ...[
        const SizedBox(height: 16),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Danger Zone',
            style: TextStyle(
              color: EchoTheme.danger,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        ListTile(
          onTap: _deleteGroup,
          leading: const Icon(
            Icons.delete_forever_outlined,
            color: EchoTheme.danger,
          ),
          title: const Text(
            'Delete Group',
            style: TextStyle(
              color: EchoTheme.danger,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            'Permanently delete this group and all its messages.',
            style: TextStyle(
              color: EchoTheme.danger.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ),
      ],
      const SizedBox(height: 24),
    ];
  }
}
