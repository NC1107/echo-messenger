// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Composer key-event routing: push-to-talk, Escape-dismiss priority chain,
/// modifier shortcuts (copy / cut / paste / bold / italic / strike), markdown
/// wrap, mention-picker keyboard nav, and the arrow-up edit-last shortcut.
extension _KeyboardHandling on ChatInputBarState {
  /// Handles push-to-talk key events. Returns true if the event was consumed.
  bool _handlePushToTalk(
    KeyEvent event,
    VoiceSettingsState voiceSettings,
    String? effectiveActiveVoiceChannelId,
  ) {
    final pttKeyId = voiceSettings.pushToTalkKeyId;
    final isPttKey = event.logicalKey.keyId.toString() == pttKeyId;
    final canPushToTalk =
        voiceSettings.pushToTalkEnabled &&
        effectiveActiveVoiceChannelId != null;

    if (!canPushToTalk || !isPttKey) return false;

    final allowCapture =
        !voiceSettings.selfMuted && !voiceSettings.selfDeafened;
    if (event is KeyDownEvent && allowCapture) {
      ref.read(voiceRtcProvider.notifier).setCaptureEnabled(true);
      _syncVoiceState();
    } else if (event is KeyUpEvent) {
      ref.read(voiceRtcProvider.notifier).setCaptureEnabled(false);
      _syncVoiceState();
    }
    return false; // don't consume -- let other handlers also run
  }

  /// Handles the Escape key by dismissing the highest-priority
  /// composer-modal state (mention picker → inline picker → media
  /// picker → pending attachments → edit mode → reply state).  Each
  /// dismissal is a no-op if the corresponding state isn't active.
  void _handleEscapeKey() {
    if (_mentionController.showPicker) {
      _mentionController.dismiss();
    } else if (_showInlinePicker) {
      setState(() => _showInlinePicker = false);
      _inputFocusNode.requestFocus();
    } else if (_showMediaPicker) {
      setState(() => _showMediaPicker = false);
      _inputFocusNode.requestFocus();
    } else if (_hasPendingAttachment) {
      _clearAllPendingAttachments();
    } else if (_isEditing) {
      _cancelEditMode();
    } else if (ref.read(chatProvider).replyToMessage != null) {
      ref.read(chatProvider.notifier).clearReplyTo();
    }
  }

  /// Handles Ctrl+V paste shortcut. Returns a [KeyEventResult] indicating
  /// whether the event was consumed.
  ///
  /// Previously returned `ignored` on web and Linux, which meant
  /// `_handlePaste()` (including image paste) was never called on those
  /// platforms. Now always invokes `_handlePaste()` and marks handled.
  KeyEventResult _handlePasteShortcut() {
    _handlePaste();
    return KeyEventResult.handled;
  }

  /// Handles Ctrl+C / Ctrl+X copy/cut shortcuts. Returns a [KeyEventResult]
  /// indicating whether the event was consumed.
  KeyEventResult _handleCopyCutShortcut(bool isCut) {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) {
      return KeyEventResult.ignored;
    }
    final sel = _messageController.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final selected = _messageController.text.substring(sel.start, sel.end);
      Clipboard.setData(ClipboardData(text: selected));
      if (isCut) {
        _messageController.text = _messageController.text.replaceRange(
          sel.start,
          sel.end,
          '',
        );
        _messageController.selection = TextSelection.collapsed(
          offset: sel.start,
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Handle Ctrl/Cmd key shortcuts (paste, copy, cut).
  KeyEventResult _handleModifierShortcut(KeyEvent event) {
    final isCtrlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!isCtrlOrMeta) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      return _handlePasteShortcut();
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      return _handleCopyCutShortcut(false);
    }
    if (event.logicalKey == LogicalKeyboardKey.keyX) {
      // Ctrl+Shift+X = strikethrough; plain Ctrl+X = cut.
      if (HardwareKeyboard.instance.isShiftPressed) {
        return _applyMarkdownWrap(open: '~~', close: '~~');
      }
      return _handleCopyCutShortcut(true);
    }
    if (event.logicalKey == LogicalKeyboardKey.keyB &&
        !HardwareKeyboard.instance.isShiftPressed) {
      return _applyMarkdownWrap(open: '**', close: '**');
    }
    if (event.logicalKey == LogicalKeyboardKey.keyI &&
        !HardwareKeyboard.instance.isShiftPressed) {
      return _applyMarkdownWrap(open: '*', close: '*');
    }
    return KeyEventResult.ignored;
  }

  /// Wrap the current selection with [open]/[close] markers. When nothing is
  /// selected, insert both markers at the cursor and leave the caret between
  /// them so the user can immediately type. Returns [KeyEventResult.handled]
  /// so the key does not also reach the underlying TextField.
  KeyEventResult _applyMarkdownWrap({
    required String open,
    required String close,
  }) {
    final text = _messageController.text;
    final sel = _messageController.selection;
    if (!sel.isValid) return KeyEventResult.ignored;

    if (sel.isCollapsed) {
      final cursor = sel.start;
      final newText =
          text.substring(0, cursor) + open + close + text.substring(cursor);
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursor + open.length),
      );
      return KeyEventResult.handled;
    }

    final before = text.substring(0, sel.start);
    final selected = text.substring(sel.start, sel.end);
    final after = text.substring(sel.end);
    final newText = '$before$open$selected$close$after';
    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: sel.start + open.length,
        extentOffset: sel.end + open.length,
      ),
    );
    return KeyEventResult.handled;
  }

  /// Up arrow with empty input: edit last own message (Discord behavior).
  /// #582: skip on encrypted conversations to avoid surfacing an edit flow
  /// the server will reject.
  KeyEventResult _handleArrowUpEditLast() {
    if (!_isTextEmpty || _isEditing) return KeyEventResult.ignored;
    if (widget.conversation.isEncrypted) return KeyEventResult.ignored;
    final messages = ref
        .read(chatProvider)
        .messagesForConversation(widget.conversation.id);
    final myUserId = ref.read(authProvider).userId ?? '';
    final lastOwn = messages
        .where((m) => m.isMine && m.fromUserId == myUserId)
        .lastOrNull;
    if (lastOwn != null) {
      enterEditMode(lastOwn);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onKeyEvent(
    FocusNode _,
    KeyEvent event,
    VoiceSettingsState voiceSettings,
    String? effectiveActiveVoiceChannelId,
  ) {
    _handlePushToTalk(event, voiceSettings, effectiveActiveVoiceChannelId);

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final mentionResult = _handleMentionPickerIfActive(event);
    if (mentionResult != KeyEventResult.ignored) return mentionResult;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleEscapeKey();
    }

    final submitResult = _handleEnterSubmit(event);
    if (submitResult != KeyEventResult.ignored) return submitResult;

    final modResult = _handleModifierShortcut(event);
    if (modResult != KeyEventResult.ignored) return modResult;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return _handleArrowUpEditLast();
    }

    return KeyEventResult.ignored;
  }

  // Mention picker keyboard nav takes precedence — Tab/Enter accept the
  // selected row, arrows move it, Escape closes the picker (without
  // also bubbling Escape through to message edit-cancel). Space falls
  // through — extractMentionQuery sees the space and closes the picker,
  // leaving the literal "@" in the text.
  KeyEventResult _handleMentionPickerIfActive(KeyDownEvent event) {
    if (!_mentionController.showPicker) return KeyEventResult.ignored;
    return _handleMentionPickerKey(event);
  }

  KeyEventResult _handleEnterSubmit(KeyDownEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _isEditing ? _submitEdit() : _sendMessage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Keyboard handler for the mention picker overlay. Returns
  /// [KeyEventResult.ignored] when the picker should *not* consume the
  /// event (e.g. Space, so the picker auto-dismisses via the query
  /// extractor).
  KeyEventResult _handleMentionPickerKey(KeyDownEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.tab ||
        (event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _acceptMentionSelection();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveMentionSelection(_MentionMove.down);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveMentionSelection(_MentionMove.up);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _mentionController.dismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
