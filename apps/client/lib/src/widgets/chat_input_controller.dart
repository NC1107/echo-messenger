import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;
import 'package:record/record.dart';

import '../models/chat_message.dart';
import 'input/mention_controller.dart';
import 'input/pending_attachments_strip.dart' show PendingAttachment;

/// Non-rendering state controller for [ChatInputBar].
///
/// Owns the text composer + edit state, attachments,
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

  // --- Pending attachments -------------------------------------------------
  //
  // Pending attachments staged for the current send. Single-pick stages
  // one entry (with caption-and-send flow); multi-pick stages all picked
  // files here so the user can review, cancel individual files, and watch
  // progress before sending. Each entry carries its own ValueNotifier for
  // upload progress so chip rebuilds don't ripple through the whole bar.

  final List<PendingAttachment> pendingAttachments = [];

  bool get hasPendingAttachment => pendingAttachments.isNotEmpty;
  bool get isAnyPendingAttachmentUploading =>
      pendingAttachments.any((a) => a.isUploading);
  bool get allPendingAttachmentsReady =>
      pendingAttachments.isNotEmpty &&
      pendingAttachments.every((a) => a.uploadedUrl != null);

  // --- Voice recording -----------------------------------------------------
  //
  // The amplitude tick runs every 100ms while `isRecording` is true. The
  // [recordingTimer] is cancelled in [dispose] so it never fires after the
  // widget is gone — same guarantee `_recordingTimer?.cancel()` gave on the
  // old `ChatInputBarState.dispose()`.

  final AudioRecorder recorder = AudioRecorder();
  bool isRecording = false;
  DateTime? recordingStartTime;
  Timer? recordingTimer;
  Duration recordingDuration = Duration.zero;
  final List<double> recordingAmplitudes = [];

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
    // Voice ticker MUST be cancelled before the recorder is torn down so a
    // late tick doesn't fire `getAmplitude` on a disposed recorder.
    recordingTimer?.cancel();
    recordingTimer = null;
    recorder.dispose();
    // Release every staged attachment's ValueNotifier (#623). Mark each
    // cancelled first so any in-flight upload's success setState short-
    // circuits before touching disposed state.
    for (final att in pendingAttachments) {
      att.cancelled = true;
      att.dispose();
    }
    pendingAttachments.clear();
    text.dispose();
    focus.dispose();
    mention.dispose();
    super.dispose();
  }
}
