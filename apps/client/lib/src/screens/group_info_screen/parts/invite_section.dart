// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Invite-link generation + clipboard copy.
extension _InviteSection on _GroupInfoScreenState {
  /// Calls `POST /api/groups/:id/invites` to generate a fresh invite token,
  /// then copies the returned URL to the clipboard.
  Future<void> _generateAndCopyInviteLink() async {
    setState(() => _isGeneratingInvite = true);
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse(
                '$serverUrl/api/groups/${widget.conversationId}/invites',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: '{}',
            ),
          );
      if (!mounted) return;
      if (response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final url = data['url'] as String? ?? '';
        if (mounted) {
          await copyToClipboard(
            context,
            url,
            successMessage: 'Invite link copied to clipboard',
          );
        }
      } else {
        String msg = 'Failed to generate invite link';
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          msg = body['error'] as String? ?? msg;
        } catch (_) {}
        if (mounted) {
          ToastService.show(context, msg, type: ToastType.error);
        }
      }
    } catch (_) {
      if (mounted) {
        ToastService.show(
          context,
          'Could not reach server',
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isGeneratingInvite = false);
    }
  }
}
