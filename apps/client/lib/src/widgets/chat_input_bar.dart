import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/settings/privacy_section.dart'
    show readPreserveOriginalFilenames;
import '../services/slash_commands.dart';
import '../services/sound_service.dart';
import '../services/toast_service.dart';
import '../services/chunked_upload_client.dart';
import '../services/upload_client.dart';
import '../services/emoji_shortcodes.dart';
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import '../theme/responsive.dart';
import '../utils/clipboard_image_helper.dart';
import 'chat_input_controller.dart';
import 'image_annotation_editor.dart';
import 'chat_input_bar/attach_file_button.dart';
import 'chat_input_bar/file_pickers.dart' as pickers;
import 'chat_input_bar/attach_option.dart';
import 'chat_input_bar/media_marker_helpers.dart';
import 'chat_input_bar/media_picker_toggle.dart';
import 'echo_bottom_sheet.dart';
import 'input_dialog.dart';
import 'chat_input_bar/recording_row.dart';
import 'chat_input_bar/send_button.dart';
import 'chat_input_bar/upload_helpers.dart';
import 'message/image_attachment.dart' show cacheImageDimensions;
import 'chat_input/formatting_toolbar.dart';
import 'input/markdown_toolbar.dart';
import 'input/pending_attachments_strip.dart';
import 'input/input_status_bar.dart';
import 'input/mention_autocomplete.dart';
import 'input/mention_controller.dart';
import 'input/slash_command_autocomplete.dart';
import 'input/reply_preview_bar.dart';
import 'media_picker_panel.dart';
import 'mobile_media_picker_panel.dart';

part 'chat_input_bar/parts/attachments.dart';
part 'chat_input_bar/parts/build_helpers.dart';
part 'chat_input_bar/parts/draft_persistence.dart';
part 'chat_input_bar/parts/edit_mode.dart';
part 'chat_input_bar/parts/keyboard_handling.dart';
part 'chat_input_bar/parts/media_picker.dart';
part 'chat_input_bar/parts/recording_handling.dart';
part 'chat_input_bar/parts/send_handling.dart';

/// Extracted chat input bar from ChatPanel.
///
/// Manages:
/// - Text composition with mention autocomplete
/// - Attachment picking, upload preview, and clipboard paste
/// - Emoji / GIF picker panels
/// - Edit mode for existing messages
/// - Keyboard shortcuts (Enter to send, Shift+Enter newline, Escape, Ctrl+V)
/// - Push-to-talk key handling
///
/// Exposes [enterEditMode] as a public method so the parent can invoke it
/// via `GlobalKey<ChatInputBarState>`.
///
/// The state class is split across `chat_input_bar/parts/*.dart` files via
/// `part of` declarations. The parent file owns the widget, the public API,
/// the state fields, lifecycle, and `build()`. Each part file contains a
/// library-private extension on [ChatInputBarState] that groups one slice
/// of behaviour (drafts, send, attachments, edit, recording, media picker,
/// keyboard, and build helpers).
class ChatInputBar extends ConsumerStatefulWidget {
  final Conversation conversation;
  final String? selectedTextChannelId;
  final String? effectiveActiveVoiceChannelId;
  final List<String> typingUsers;
  final VoidCallback onMessageSent;
  final VoidCallback? onMediaPickerChanged;

  const ChatInputBar({
    super.key,
    required this.conversation,
    this.selectedTextChannelId,
    this.effectiveActiveVoiceChannelId,
    this.typingUsers = const [],
    required this.onMessageSent,
    this.onMediaPickerChanged,
  });

  @override
  ConsumerState<ChatInputBar> createState() => ChatInputBarState();
}

/// Direction of a mention-picker selection move, expressed as visual
/// intent rather than a raw +1 / -1 delta. The picker ListView uses
/// `reverse: true`, so encoding the inversion here keeps the key
/// handler reading as `up` / `down`.
enum _MentionMove { up, down }

class ChatInputBarState extends ConsumerState<ChatInputBar>
    with SingleTickerProviderStateMixin {
  // Text, focus, edit, mention state lives on [_controller]; getters preserve old call-site shape.
  late final ChatInputController _controller;
  TextEditingController get _messageController => _controller.text;
  FocusNode get _inputFocusNode => _controller.focus;

  bool _isTextEmpty = true;
  bool _showMediaPicker = false;

  /// True when the composer has wrapped to 2+ visible lines (either by
  /// explicit newlines or by soft-wrapping long text). When true, the
  /// attach "+" and emoji toggle are stacked vertically to reclaim
  /// horizontal space for the text field.
  bool _isMultiline = false;

  /// Soft threshold for switching the input row into multi-line layout when
  /// the text gets long enough that it'd visually wrap. Derived from the
  /// current viewport width in `build()` (Inter 14px ≈ 7px/char average,
  /// minus padding/icons), clamped so a 4K screen still has a sane upper
  /// bound and a tiny mobile one still triggers eventually.
  int _multilineCharThreshold = 40;

  /// Inline picker visible on mobile (replaces keyboard).
  bool _showInlinePicker = false;

  /// On mobile, the markdown formatting toolbar is hidden by default and
  /// toggled on via the "Aa" entry in the attach (+) sheet. On desktop the
  /// toolbar is always visible and this flag is ignored.
  bool _showFormatToolbarOnMobile = false;

  /// Drives the [SelectionFormattingPopover] fade animation (kept for API
  /// symmetry; the popover mounts/unmounts based on selection state).
  late final AnimationController _formattingBarAnim;

  /// Last known keyboard height -- used to size the inline picker so it
  /// occupies the same space the keyboard did.
  double _lastKeyboardHeight = 0;

  // File picker guard
  bool _isPickingFile = false;

  // Edit mode on [_controller]; setter goes through enterEditMode/exitEditMode for consistent notifier order.
  ChatMessage? get _editingMessage => _controller.editingMessage;
  bool get _isEditing => _controller.isEditing;

  // Mention controller is composed (not inherited) for unit-testability (#513).
  MentionComposerController get _mentionController => _controller.mention;

  // Pending attachments + voice recording on [_controller]; getters preserve old call sites.
  List<PendingAttachment> get _pendingAttachments =>
      _controller.pendingAttachments;
  bool get _hasPendingAttachment => _controller.hasPendingAttachment;
  bool get _isAnyPendingAttachmentUploading =>
      _controller.isAnyPendingAttachmentUploading;
  bool get _allPendingAttachmentsReady =>
      _controller.allPendingAttachmentsReady;

  AudioRecorder get _recorder => _controller.recorder;
  bool get _isRecording => _controller.isRecording;
  set _isRecording(bool v) => _controller.isRecording = v;
  DateTime? get _recordingStartTime => _controller.recordingStartTime;
  set _recordingStartTime(DateTime? v) => _controller.recordingStartTime = v;
  Timer? get _recordingTimer => _controller.recordingTimer;
  set _recordingTimer(Timer? v) => _controller.recordingTimer = v;
  Duration get _recordingDuration => _controller.recordingDuration;
  set _recordingDuration(Duration v) => _controller.recordingDuration = v;
  List<double> get _recordingAmplitudes => _controller.recordingAmplitudes;

  // Draft auto-save
  static const _draftKeyPrefix = 'chat_draft_';
  Timer? _draftSaveTimer;
  // Suppresses draft saves during cancel-edit to avoid race with _loadDraft.
  bool _suppressDraftSave = false;

  /// Index of the selected row in the mention picker. Reset to 0 each time
  /// the picker opens or the query changes so the first match is always
  /// the keyboard-accept target.
  int _mentionPickerIndex = 0;
  String _lastMentionQuery = '';
  bool _lastMentionShowing = false;
  // Cached candidate list (recomputing per keystroke allocated a fresh filtered list each time).
  List<String> _cachedMentionCandidates = const [];

  @override
  void initState() {
    super.initState();
    _controller = ChatInputController();
    _formattingBarAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _messageController.addListener(_onTextChanged);
    _mentionController.addListener(_onMentionChanged);
    _loadDraft(widget.conversation.id);
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation.id != oldWidget.conversation.id) {
      // Save draft for the outgoing conversation
      _saveDraftImmediate(oldWidget.conversation.id, _messageController.text);
      _draftSaveTimer?.cancel();

      _mentionController.dismiss();
      // Release ALL staged attachment notifiers on conv switch (#623 used to leak all but the last).
      _clearAllPendingAttachments();
      _messageController.clear();
      _controller.exitEditMode();
      _isTextEmpty = true;
      _showMediaPicker = false;
      _showInlinePicker = false;
      ref.read(chatProvider.notifier).clearReplyTo();

      // Load draft for the new conversation
      _loadDraft(widget.conversation.id);
    }
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _formattingBarAnim.dispose();
    _messageController.removeListener(_onTextChanged);
    _mentionController.removeListener(_onMentionChanged);
    // _controller.dispose tears down all sub-controllers in the right order (#513, #623).
    _controller.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Public API (called by parent via GlobalKey<ChatInputBarState>)
  // ---------------------------------------------------------------------------

  void enterEditMode(ChatMessage message) {
    // Clear any active reply — editing and replying are mutually exclusive.
    ref.read(chatProvider.notifier).clearReplyTo();
    setState(() {
      _controller.enterEditMode(message);
      _isTextEmpty = false;
    });
    _inputFocusNode.requestFocus();
  }

  /// Focus the input text field (e.g. after starting a reply).
  void requestInputFocus() {
    _inputFocusNode.requestFocus();
  }

  /// Pre-fill the input with [text] and focus it.
  /// Used by the "Say hi" CTA in the empty conversation placeholder.
  void preFillText(String text) {
    setState(() {
      _messageController.text = text;
      _isTextEmpty = text.trim().isEmpty;
    });
    _messageController.selection = TextSelection.collapsed(offset: text.length);
    _inputFocusNode.requestFocus();
  }

  /// Attach a file dropped from the OS (via drag-and-drop).
  ///
  /// Reads bytes from [path] (or uses [bytes] directly if provided),
  /// resolves the MIME type from [fileName], and starts the upload preview
  /// flow identical to picking a file via the attach button.
  Future<void> attachDroppedFile({
    required String path,
    required String fileName,
    Uint8List? bytes,
  }) async {
    Uint8List? fileBytes = bytes;
    if (fileBytes == null && !kIsWeb) {
      try {
        fileBytes = await File(path).readAsBytes();
      } catch (e) {
        debugPrint('[ChatInput] Failed to read dropped file: $e');
      }
    }
    if (fileBytes == null) {
      if (mounted) {
        ToastService.show(
          context,
          'Could not read dropped file',
          type: ToastType.error,
        );
      }
      return;
    }

    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final mime = kMimeTypes[ext] ?? ['application', kOctetStream];

    _setPendingAttachment(
      bytes: fileBytes,
      fileName: fileName,
      mimeType: '${mime[0]}/${mime[1]}',
      ext: ext.isNotEmpty ? ext : 'bin',
    );
  }

  /// Whether the media picker is currently shown. Exposed for ChatPanel
  /// to render the picker in its own overlay Stack.
  bool get showMediaPicker => _showMediaPicker;

  /// Expose inline picker state for ChatPanel layout adjustments.
  bool get showInlinePicker => _showInlinePicker;

  /// Build the media picker panel. Called by ChatPanel to render it
  /// above the message list (not inside the input bar's Stack).
  Widget buildMediaPickerPanel() {
    return MediaPickerPanel(
      onEmojiSelected: (category, emoji) {
        _insertEmoji(emoji.emoji);
        setState(() => _showMediaPicker = false);
        _inputFocusNode.requestFocus();
      },
      onGifSelected: (gifUrl, slug) {
        setState(() => _showMediaPicker = false);
        // GIF is an external URL -- no upload needed.
        _setPendingExternalAttachment(
          url: gifUrl,
          fileName: 'gif',
          mimeType: kImageGifMimeType,
          ext: 'gif',
        );
      },
      onClose: () {
        setState(() => _showMediaPicker = false);
        _inputFocusNode.requestFocus();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final myUserId = ref.watch(authProvider.select((s) => s.userId)) ?? '';
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final replyToMessage = ref.watch(
      chatProvider.select((s) => s.replyToMessage),
    );

    // Multiline threshold derived from viewport so flip happens when text actually wraps.
    final width = MediaQuery.sizeOf(context).width;
    _multilineCharThreshold = ((width - 120) / 8).clamp(35, 120).round();

    final displayName = conv.displayName(myUserId);
    final typingText = computeTypingText(
      typingUsers: widget.typingUsers,
      isGroup: conv.isGroup,
      displayName: displayName,
    );
    final showInputStatus = _isEditing || widget.typingUsers.isNotEmpty;
    final inputStatusText = computeInputStatusText(
      isEditing: _isEditing,
      typingText: typingText,
      hasTypingUsers: widget.typingUsers.isNotEmpty,
    );
    final isMobileLayout = Responsive.isMobile(context);
    final showMediaPicker = _showMediaPicker && !isMobileLayout;
    final effectiveActiveVoiceChannelId = widget.effectiveActiveVoiceChannelId;

    // Track keyboard height so the inline picker can match it.
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardHeight > 150) {
      _lastKeyboardHeight = keyboardHeight;
    }

    // When inline picker is showing, don't add bottom safe area padding
    // (the picker itself covers that space).
    final bottomPadding = _showInlinePicker
        ? 8.0
        : 20.0 + MediaQuery.of(context).padding.bottom;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAutocompletePickers(),
            // Input area
            Container(
              padding: EdgeInsets.fromLTRB(
                20,
                EchoSpacing.sm,
                20,
                bottomPadding,
              ),
              color: context.chatBg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showInputStatus)
                    InputStatusBar(
                      isEditing: _isEditing,
                      statusText: inputStatusText,
                      onCancelEdit: _cancelEditMode,
                    ),
                  // AnimatedSize slides reply bar in/out instead of snapping.
                  AnimatedSize(
                    duration: MotionDurations.standard,
                    curve: MotionCurves.entrance,
                    alignment: Alignment.topCenter,
                    child: replyToMessage != null
                        ? ReplyPreviewBar(
                            replyToMessage: replyToMessage,
                            onDismiss: () =>
                                ref.read(chatProvider.notifier).clearReplyTo(),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // Pending-attachments strip — one chip per staged file
                  // with thumbnail, name, size, progress, and cancel.
                  if (_hasPendingAttachment)
                    PendingAttachmentsStrip(
                      attachments: _pendingAttachments,
                      onCancel: _removePendingAttachment,
                      onAnnotate: _annotatePendingAttachment,
                    ),
                  // Markdown toolbar (Discord pattern): only render when the
                  // user has highlighted text in the composer. Mobile keeps
                  // the "+" sheet opt-in so the row doesn't reflow under the
                  // keyboard mid-type.
                  if (!isMobileLayout || _showFormatToolbarOnMobile)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _messageController,
                      builder: (context, value, _) {
                        final hasSelection =
                            value.selection.isValid &&
                            value.selection.start != value.selection.end;
                        if (!hasSelection) return const SizedBox.shrink();
                        return MarkdownToolbar(
                          controller: _messageController,
                          onLinkTap: _showLinkDialog,
                        );
                      },
                    ),
                  _buildInputRow(
                    showMediaPicker: showMediaPicker,
                    isMobileLayout: isMobileLayout,
                    voiceSettings: voiceSettings,
                    effectiveActiveVoiceChannelId:
                        effectiveActiveVoiceChannelId,
                  ),
                ],
              ),
            ),
            // Inline mobile picker (replaces keyboard)
            if (isMobileLayout) _buildInlinePicker(),
          ],
        ),
        // Media picker is rendered by ChatPanel in its own Stack (above message list).
      ],
    );
  }
}
