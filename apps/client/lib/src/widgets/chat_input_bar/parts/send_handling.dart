// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Send pipeline: trimming, slash-command interception, optimistic insert,
/// WebSocket dispatch, plus the mention-autocomplete plumbing that lives
/// alongside the input listener.
extension _SendHandling on ChatInputBarState {
  void _onMentionChanged() {
    if (!mounted) return;
    final showing = _mentionController.showPicker;
    final query = _mentionController.query;
    final changed =
        showing != _lastMentionShowing || query != _lastMentionQuery;
    if (!changed) return; // skip rebuild when nothing visible changed
    _mentionPickerIndex = 0;
    _cachedMentionCandidates = showing
        ? MentionAutocomplete.candidateValues(_filteredMentionMembers, query)
        : const [];
    _lastMentionShowing = showing;
    _lastMentionQuery = query;
    setState(() {});
  }

  /// Candidate values currently rendered by the mention picker. Cached
  /// in [_cachedMentionCandidates] and updated only in [_onMentionChanged].
  List<String> get _mentionCandidates => _cachedMentionCandidates;

  /// Accept the currently-selected mention candidate (Tab/Enter pressed
  /// while the picker is open). No-op when there are no candidates.
  void _acceptMentionSelection() {
    final candidates = _mentionCandidates;
    if (candidates.isEmpty) return;
    final idx = _mentionPickerIndex.clamp(0, candidates.length - 1);
    _handleMentionSelected(candidates[idx]);
  }

  /// Semantic direction for picker navigation. The candidate list is
  /// rendered with `reverse: true`, so the *visual* "down arrow"
  /// actually moves to a smaller index. Encapsulating that here means
  /// the key handler reads as `_MentionMove.down` rather than
  /// `_moveMentionSelection(-1)` and a future maintainer can't
  /// accidentally flip the sign (TD-22).
  void _moveMentionSelection(_MentionMove direction) {
    final candidates = _mentionCandidates;
    if (candidates.isEmpty) return;
    final delta = switch (direction) {
      _MentionMove.up => 1, // up arrow → higher index in the reverse list
      _MentionMove.down => -1, // down arrow → lower index
    };
    final next = (_mentionPickerIndex + delta) % candidates.length;
    setState(() {
      _mentionPickerIndex = next < 0 ? next + candidates.length : next;
    });
  }

  Future<void> _sendMessage() async {
    final caption = _messageController.text.trim();

    // Attachments still uploading -- don't send text-only and lose them.
    if (_hasPendingAttachment && !_allPendingAttachmentsReady) {
      if (mounted) {
        ToastService.show(
          context,
          'Attachments still uploading...',
          type: ToastType.info,
        );
      }
      return;
    }

    // If there are uploaded attachments, send them as separate messages.
    if (_hasPendingAttachment && _allPendingAttachmentsReady) {
      await _sendAttachments(caption);
      return;
    }

    // (legacy guard kept; the above already covers the in-flight case)
    if (_isAnyPendingAttachmentUploading) {
      if (mounted) {
        ToastService.show(
          context,
          'Attachment still uploading...',
          type: ToastType.info,
        );
      }
      return;
    }

    final text = caption;
    if (text.isEmpty) return;

    // Slash-command interception: parse before encrypting/sending.
    final handled = await _tryHandleSlashCommand(text);
    if (handled) return;

    await _doSend(text);
    _clearInputAndNotify();
  }

  /// Sends all pending attachments as separate messages.
  /// Caption goes on the FIRST attachment so it stays attached visually;
  /// the rest are bare media markers. Matches Discord / iMessage.
  Future<void> _sendAttachments(String caption) async {
    final attachments = List<PendingAttachment>.from(_pendingAttachments);
    _clearAllPendingAttachments();
    _messageController.clear();
    _saveDraftImmediate(widget.conversation.id, '');
    for (var i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      final marker = buildMediaMarker(
        extension: att.ext,
        url: att.uploadedUrl!,
      );
      await _doSend(marker);
      if (i == 0 && caption.isNotEmpty) {
        await _doSend(caption);
      }
    }
    widget.onMessageSent();
  }

  /// Tries to dispatch [text] as a slash command.
  /// Returns true if the command was handled (caller should return early).
  Future<bool> _tryHandleSlashCommand(String text) async {
    final slashCmd = parseSlashCommand(text);
    if (slashCmd == null) return false;

    String? rewrittenText;
    final handled = await dispatchSlashCommand(
      slashCmd,
      widget.conversation,
      ref,
      context,
      onRewrite: (newText) {
        rewrittenText = newText;
      },
    );
    if (!handled) return false;

    _messageController.clear();
    _saveDraftImmediate(widget.conversation.id, '');
    // If a fun command rewrote the text, send the rewritten version.
    if (rewrittenText != null) {
      await _doSend(rewrittenText!);
      _dismissPickers();
      widget.onMessageSent();
    }
    return true;
  }

  /// Clears the text field, saves an empty draft, dismisses pickers,
  /// and fires the onMessageSent callback.
  void _clearInputAndNotify() {
    _messageController.clear();
    _saveDraftImmediate(widget.conversation.id, '');
    _dismissPickers();
    widget.onMessageSent();
  }

  /// Hides the media/inline pickers if they are currently open.
  void _dismissPickers() {
    if (_showMediaPicker) setState(() => _showMediaPicker = false);
    if (_showInlinePicker) setState(() => _showInlinePicker = false);
  }

  Future<void> _doSend(String text) async {
    if (text.isEmpty) return;

    // Expand emoji shortcodes (e.g., :smile: → 😄) at send-time
    final expandedText = expandEmojiShortcodes(text);

    final conv = widget.conversation;
    final myUserId = ref.read(authProvider).userId ?? '';
    final chatState = ref.read(chatProvider);
    final replyTo = chatState.replyToMessage;

    String peerUserId = '';
    String? channelId;
    if (!conv.isGroup) {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      peerUserId = peer?.userId ?? '';
    } else {
      final channels = ref.read(channelsProvider).channelsFor(conv.id);
      channelId =
          widget.selectedTextChannelId ??
          channels.where((c) => c.isText).firstOrNull?.id;
    }

    ref
        .read(chatProvider.notifier)
        .addOptimistic(
          peerUserId,
          expandedText,
          myUserId,
          conversationId: conv.id,
          channelId: channelId,
          replyToId: replyTo?.id,
          replyToContent: replyTo?.content,
          replyToUsername: replyTo?.fromUsername,
        );

    // Haptic + chime on local commit (desktop no-op; iOS respects system-haptics setting).
    HapticFeedback.lightImpact();
    SoundService().playMessageSent().ignore();

    // Clear reply state after capturing the reply info.
    if (replyTo != null) {
      ref.read(chatProvider.notifier).clearReplyTo();
    }

    try {
      if (conv.isGroup) {
        await ref
            .read(websocketProvider.notifier)
            .sendGroupMessage(
              conv.id,
              expandedText,
              channelId: channelId,
              replyToId: replyTo?.id,
            );
      } else {
        await ref
            .read(websocketProvider.notifier)
            .sendMessage(
              peerUserId,
              expandedText,
              conversationId: conv.id,
              replyToId: replyTo?.id,
            );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to send message',
          type: ToastType.error,
        );
      }
    }
  }

  void _onInputChanged(String text) {
    // Don't send typing indicator while editing an existing message —
    // recipients would see "X is typing..." when X is only editing.
    if (!_isEditing) {
      final conv = widget.conversation;
      if (text.isNotEmpty) {
        ref
            .read(websocketProvider.notifier)
            .sendTyping(
              conv.id,
              channelId: conv.isGroup ? widget.selectedTextChannelId : null,
            );
      }
    }
    _detectMention(text);
  }

  void _detectMention(String text) {
    _mentionController.detect(
      text: text,
      cursorPosition: _messageController.selection.baseOffset,
      isGroup: widget.conversation.isGroup,
    );
  }

  void _handleMentionSelected(String username) {
    final text = _messageController.text;
    final cursorPos = _messageController.selection.baseOffset;

    // cursorPos < 0 = field never focused; bail before silently dismissing the picker.
    if (cursorPos < 0) return;

    _messageController.value = insertMention(
      text: text,
      cursorPosition: cursorPos,
      username: username,
    );

    _mentionController.dismiss();
    _inputFocusNode.requestFocus();
  }

  List<ConversationMember> get _filteredMentionMembers {
    final myUserId = ref.read(authProvider).userId ?? '';
    return MentionComposerController.filterMembers(
      widget.conversation.members,
      myUserId,
    );
  }

  /// Whether the signed-in user has admin or owner role in the current
  /// conversation.  Always `false` for DMs (non-group conversations).
  bool get _currentUserIsGroupAdmin {
    if (!widget.conversation.isGroup) return false;
    final myUserId = ref.read(authProvider).userId ?? '';
    final me = widget.conversation.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final role = me?.role?.toLowerCase();
    return role == 'admin' || role == 'owner';
  }
}
