import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;

import '../models/chat_message.dart';
import 'input/mention_controller.dart';

/// Non-rendering state controller for [ChatInputBar].
///
/// Owns the text composer + edit state + (in later slices) attachments,
/// voice recording, and mention autocomplete bridging. Composes (not
/// inherits) the existing [MentionComposerController] so its dispose hook
/// is wired through this controller's dispose.
///
/// Architectural contract:
/// - controllers are plain `ChangeNotifier`s, never Riverpod providers;
/// - controllers receive data via method args; they never hold a
///   `WidgetRef` or call `ref.watch/read/select`;
/// - `ChatInputBarState`'s public methods reachable via
///   `GlobalKey<ChatInputBarState>` keep IDENTICAL signatures (#513).
///
/// Slice 4 (#513): text controller + edit-message state. Slice 5 will move
/// attachments, voice recording state, and mention bridging.
class ChatInputController extends ChangeNotifier {
  ChatInputController({MentionComposerController? mentionController})
    : mention = mentionController ?? MentionComposerController();

  /// The text composer's [TextEditingController]. Lives here so listeners
  /// and external callers (e.g. the markdown toolbar) share a single
  /// instance with the controller's edit-state.
  final TextEditingController text = TextEditingController();

  /// Focus node for the input text field. Owned here so the controller's
  /// `requestFocus` helpers don't have to thread a node through the widget.
  final FocusNode focus = FocusNode();

  /// Composed (not inherited) mention controller. Disposed by this
  /// controller's [dispose] so the widget no longer has to remember to
  /// release it.
  final MentionComposerController mention;

  // --- Edit mode -----------------------------------------------------------
  //
  // The widget enters/exits edit mode through [enterEditMode]/[exitEditMode].
  // [_editingMessage] is the canonical source of truth; the widget mirrors
  // through the `isEditing` getter without keeping a duplicate field.

  ChatMessage? _editingMessage;
  ChatMessage? get editingMessage => _editingMessage;
  bool get isEditing => _editingMessage != null;

  /// Enter edit mode for [message]: stamp the text controller with its
  /// content, clear the empty-text flag, and notify listeners so the widget
  /// can re-render its status bar / hint text.
  ///
  /// Does NOT touch focus — the widget pairs this with
  /// `_inputFocusNode.requestFocus()` after the `setState`. Keeping focus
  /// in the widget preserves the slice-4 API contract: no new public
  /// surface on `ChatInputBarState`.
  void enterEditMode(ChatMessage message) {
    _editingMessage = message;
    text.text = message.content;
    notifyListeners();
  }

  /// Exit edit mode (called from cancel + submit paths). Caller is
  /// responsible for clearing the text controller — `exitEditMode` itself
  /// only flips the flag.
  void exitEditMode() {
    if (_editingMessage == null) return;
    _editingMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    mention.dispose();
    super.dispose();
  }
}
