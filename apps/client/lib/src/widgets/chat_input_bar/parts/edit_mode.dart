// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Edit-mode helpers: cancel restores the draft, submit issues the PUT and
/// surfaces the encrypted-conversation rejection toast (#582).
extension _EditMode on ChatInputBarState {
  void _cancelEditMode() {
    _draftSaveTimer?.cancel();
    _suppressDraftSave = true;
    setState(() {
      _controller.exitEditMode();
      _messageController.clear();
      _isTextEmpty = true;
    });
    // Restore the saved draft (if any) after leaving edit mode.
    _loadDraft(widget.conversation.id).then((_) {
      _suppressDraftSave = false;
    });
  }

  Future<void> _submitEdit() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _editingMessage == null) return;

    final conv = widget.conversation;
    // #582: never submit edits on encrypted convs (broadcasts plaintext); server also returns 409.
    if (conv.isEncrypted) {
      _cancelEditMode();
      if (mounted) {
        ToastService.show(
          context,
          'Edit unsupported for encrypted messages.',
          type: ToastType.info,
        );
      }
      return;
    }
    final messageId = _editingMessage!.id;
    final serverUrl = ref.read(serverUrlProvider);

    // Optimistically update local state
    ref.read(chatProvider.notifier).editMessage(conv.id, messageId, text);
    _cancelEditMode();

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.put(
              Uri.parse('$serverUrl/api/messages/$messageId'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'content': text}),
            ),
          );
      // 409 = encrypted-conv edit rejection (#582); surface non-fatal toast for rollback.
      if (response.statusCode == 409 && mounted) {
        ToastService.show(
          context,
          'Edit unsupported for encrypted messages.',
          type: ToastType.info,
        );
      } else if (response.statusCode >= 400 && mounted) {
        ToastService.show(
          context,
          'Failed to edit message',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to edit message',
          type: ToastType.error,
        );
      }
    }
  }
}
