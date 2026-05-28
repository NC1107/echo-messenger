// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Composer build helpers: the text-field with its key handler, the
/// markdown link-insert dialog, the main input row with attach + send
/// buttons, the autocomplete pickers, and the animated inline-picker for
/// mobile.
extension _BuildHelpers on ChatInputBarState {
  Widget _buildTextField({
    required bool showMediaPicker,
    required bool isMobileLayout,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
  }) {
    // Mobile clamp to 6 lines so the keyboard+draft don't eat >50% height.
    final composerMaxLines = isMobileLayout ? 6 : 10;
    return Expanded(
      child: Focus(
        onKeyEvent: (node, event) => _onKeyEvent(
          node,
          event,
          voiceSettings,
          effectiveActiveVoiceChannelId,
        ),
        child: TextField(
          controller: _messageController,
          focusNode: _inputFocusNode,
          maxLines: composerMaxLines,
          minLines: 1,
          maxLength: 4000,
          buildCounter:
              (
                context, {
                required currentLength,
                required isFocused,
                required maxLength,
              }) {
                if (currentLength <= 3200) return null;
                final counterColor = currentLength > 3900
                    ? EchoTheme.danger
                    : context.textMuted;
                return Text(
                  '$currentLength/$maxLength',
                  style: TextStyle(color: counterColor, fontSize: 11),
                );
              },
          autofillHints: const [],
          style: TextStyle(fontSize: 14, color: context.textPrimary),
          decoration: InputDecoration(
            hintText: _isEditing ? 'Edit your message…' : 'Message — encrypted',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onChanged: _onInputChanged,
          onTap: () {
            if (_showInlinePicker) {
              setState(() => _showInlinePicker = false);
            }
            if (showMediaPicker) {
              setState(() => _showMediaPicker = false);
            }
          },
          onSubmitted: (_) => _isEditing ? _submitEdit() : _sendMessage(),
        ),
      ),
    );
  }

  VoidCallback _resolvedSendAction() {
    if (_isEditing) return _submitEdit;
    return _sendMessage;
  }

  Future<void> _showLinkDialog() async {
    final url = await showEchoInputDialog(
      context,
      title: 'Insert link',
      hintText: 'https://…',
      keyboardType: TextInputType.url,
      confirmLabel: 'Insert',
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;

    final sel = _messageController.selection;
    final text = _messageController.text;
    final hasSelection = sel.isValid && sel.start != sel.end;
    final label = hasSelection ? text.substring(sel.start, sel.end) : 'link';

    if (hasSelection) {
      // Replace selection with [label](url)
      final newText =
          '${text.substring(0, sel.start)}[$label]($url)${text.substring(sel.end)}';
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: sel.start + newText.length - text.substring(sel.end).length,
        ),
      );
    } else {
      // Insert at cursor
      final pos = sel.isValid ? sel.start : text.length;
      final inserted = '[$label]($url)';
      final newText = text.substring(0, pos) + inserted + text.substring(pos);
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: pos + inserted.length),
      );
    }
    _inputFocusNode.requestFocus();
  }

  Widget _buildInputRow({
    required bool showMediaPicker,
    required bool isMobileLayout,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
  }) {
    // While recording, replace the entire input row with the recording UI.
    if (_isRecording) {
      return RecordingRow(
        recordingDuration: _recordingDuration,
        recordingAmplitudes: _recordingAmplitudes,
        onCancel: () => _stopRecording(cancel: true),
        onStop: () => _stopRecording(),
      );
    }

    final pillBorderColor = _isEditing ? context.accent : context.border;
    final inputPill = _buildInputPill(
      showMediaPicker: showMediaPicker,
      isMobileLayout: isMobileLayout,
      voiceSettings: voiceSettings,
      effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
      pillBorderColor: pillBorderColor,
    );

    return Row(
      crossAxisAlignment: _isMultiline
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.center,
      children: [
        if (!_isEditing)
          AttachFileButton(
            onPickFile: _pickFile,
            onShowMobileMenu: _showMobileAttachMenu,
          ),
        if (!_isEditing) const SizedBox(width: 4),
        if (!_isEditing) const SizedBox(width: EchoSpacing.sm),
        Expanded(child: inputPill),
        const SizedBox(width: 8),
        SendButton(
          isTextEmpty: _isTextEmpty,
          allPendingAttachmentsReady: _allPendingAttachmentsReady,
          isEditing: _isEditing,
          isDm: !widget.conversation.isGroup,
          onStartRecording: _startRecording,
          resolveSendAction: _resolvedSendAction,
        ),
      ],
    );
  }

  /// Builds the input pill (the rounded container holding the text field).
  Widget _buildInputPill({
    required bool showMediaPicker,
    required bool isMobileLayout,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
    required Color pillBorderColor,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.only(
        left: EchoSpacing.md,
        right: EchoSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: pillBorderColor, width: 1),
      ),
      child: Row(
        crossAxisAlignment: _isMultiline
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.center,
        children: [
          _buildTextField(
            showMediaPicker: showMediaPicker,
            isMobileLayout: isMobileLayout,
            voiceSettings: voiceSettings,
            effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
          ),
          MediaPickerToggle(
            showMediaPicker: showMediaPicker,
            onToggle: () => _toggleMediaPicker(isMobileLayout),
          ),
        ],
      ),
    );
  }

  /// Builds the mention and slash-command autocomplete pickers.
  /// Exactly one is visible at a time — mention picker takes priority.
  Widget _buildAutocompletePickers() {
    if (_mentionController.showPicker) {
      return MentionAutocomplete(
        members: _filteredMentionMembers,
        mentionQuery: _mentionController.query,
        selectedIndex: _mentionPickerIndex,
        onMentionSelected: _handleMentionSelected,
      );
    }
    return SlashCommandAutocomplete(
      inputText: _messageController.text,
      userIsGroupAdmin: _currentUserIsGroupAdmin,
      onSelect: (template) {
        _messageController.text = template;
        _messageController.selection = TextSelection.collapsed(
          offset: template.length,
        );
      },
    );
  }

  /// Builds the animated inline media/emoji picker that replaces the keyboard
  /// on mobile. Collapses to [SizedBox.shrink] when not shown.
  Widget _buildInlinePicker() {
    final pickerHeight = (_lastKeyboardHeight > 0 ? _lastKeyboardHeight : 280)
        .toDouble();
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      child: _showInlinePicker
          ? SizedBox(
              height: pickerHeight,
              child: MobileMediaPickerPanel(
                onEmojiSelected: (category, emoji) {
                  _insertEmoji(emoji.emoji);
                  _onInputChanged(_messageController.text);
                },
                onGifSelected: (gifUrl, slug) {
                  setState(() => _showInlinePicker = false);
                  _setPendingExternalAttachment(
                    url: gifUrl,
                    fileName: 'gif',
                    mimeType: kImageGifMimeType,
                    ext: 'gif',
                  );
                },
                onPhotoSelected: _handlePhotoSelected,
                onClose: () {
                  setState(() => _showInlinePicker = false);
                  _inputFocusNode.requestFocus();
                },
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
