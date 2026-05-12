import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;
import 'package:record/record.dart';

import '../models/chat_message.dart';
import 'input/mention_controller.dart';
import 'input/pending_attachments_strip.dart' show PendingAttachment;

/// Non-rendering state for [ChatInputBar]: text composer + edit state,
/// pending attachments, voice recording, and mention autocomplete.
/// Composes (not inherits) [MentionComposerController] so its dispose
/// runs from this controller's [dispose].
class ChatInputController extends ChangeNotifier {
  ChatInputController({MentionComposerController? mentionController})
    : mention = mentionController ?? MentionComposerController();

  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  final MentionComposerController mention;

  // Single-pick stages one entry (caption-and-send flow); multi-pick stages
  // all picked files so the user can review / cancel / watch progress before
  // sending. Each entry carries a ValueNotifier for upload progress so chip
  // rebuilds don't ripple through the whole input bar.
  final List<PendingAttachment> pendingAttachments = [];

  bool get hasPendingAttachment => pendingAttachments.isNotEmpty;
  bool get isAnyPendingAttachmentUploading =>
      pendingAttachments.any((a) => a.isUploading);
  bool get allPendingAttachmentsReady =>
      pendingAttachments.isNotEmpty &&
      pendingAttachments.every((a) => a.uploadedUrl != null);

  // Voice amplitude tick runs every 100ms while [isRecording] is true.
  // [recordingTimer] is cancelled in [dispose] before [recorder] is torn
  // down so a late tick can't fire `getAmplitude` on a disposed recorder.
  final AudioRecorder recorder = AudioRecorder();
  bool isRecording = false;
  DateTime? recordingStartTime;
  Timer? recordingTimer;
  Duration recordingDuration = Duration.zero;
  final List<double> recordingAmplitudes = [];

  ChatMessage? _editingMessage;
  ChatMessage? get editingMessage => _editingMessage;
  bool get isEditing => _editingMessage != null;

  /// Enter edit mode for [message]. Does NOT touch focus — callers pair this
  /// with `focus.requestFocus()` after their `setState`.
  void enterEditMode(ChatMessage message) {
    _editingMessage = message;
    text.text = message.content;
    notifyListeners();
  }

  /// Exit edit mode. The caller is responsible for clearing [text].
  void exitEditMode() {
    if (_editingMessage == null) return;
    _editingMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    recordingTimer?.cancel();
    recordingTimer = null;
    recorder.dispose();
    // Mark each attachment cancelled before disposing so any in-flight upload's
    // success setState short-circuits before touching disposed state (#623).
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
