// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Draft auto-save: per-conversation persistence of the composer text to
/// SharedPreferences so a half-typed message survives navigation or a
/// hot-restart. Lives as a `part of 'chat_input_bar.dart'` extension so the
/// helpers share library-private access to the [ChatInputBarState] fields.
extension _DraftPersistence on ChatInputBarState {
  Future<void> _loadDraft(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${ChatInputBarState._draftKeyPrefix}$conversationId';
    final draft = prefs.getString(key);
    if (draft != null && draft.isNotEmpty && mounted && !_isEditing) {
      _messageController.text = draft;
      setState(() => _isTextEmpty = draft.trim().isEmpty);
    }
  }

  void _scheduleDraftSave(String text) {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 600), () {
      _saveDraftImmediate(widget.conversation.id, text);
    });
  }

  Future<void> _saveDraftImmediate(String conversationId, String text) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${ChatInputBarState._draftKeyPrefix}$conversationId';
    if (text.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, text);
    }
  }

  void _onTextChanged() {
    final text = _messageController.text;
    final empty = text.trim().isEmpty;
    // Threshold recomputed from viewport so 4K doesn't flip mid-sentence.
    final multiline =
        text.contains('\n') || text.length > _multilineCharThreshold;
    if (empty != _isTextEmpty || multiline != _isMultiline) {
      setState(() {
        _isTextEmpty = empty;
        _isMultiline = multiline;
      });
    }
    // Schedule draft save when not in edit mode and not suppressed
    if (!_isEditing && !_suppressDraftSave) {
      _scheduleDraftSave(text);
    }
  }
}
