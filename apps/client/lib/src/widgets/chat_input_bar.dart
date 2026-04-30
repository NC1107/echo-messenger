import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/settings/privacy_section.dart'
    show readPreserveOriginalFilenames;
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/clipboard_image_helper.dart';
import 'input/pending_attachments_strip.dart';
import 'input/input_status_bar.dart';
import 'input/mention_autocomplete.dart';
import 'input/reply_preview_bar.dart';
import 'media_picker_panel.dart';
import 'mobile_media_picker_panel.dart';

const _kOctetStream = 'octet-stream';

/// Mirror of `MAX_FILE_SIZE` in `apps/server/src/routes/media.rs`. Both must
/// be bumped together. Cloudflare Free also caps request bodies at 100 MB,
/// so going higher than this without proxy work will 502 on prod.
const _kMaxUploadBytes = 100 * 1024 * 1024;

/// Strip the original name and return `media.{ext}` (or just `media` if the
/// filename had no extension). Used by the "preserve original filenames"
/// privacy toggle.
String _genericFilename(String original) {
  final dot = original.lastIndexOf('.');
  if (dot <= 0 || dot == original.length - 1) return 'media';
  final ext = original.substring(dot + 1).toLowerCase();
  return 'media.$ext';
}

/// Format a byte count as a human-readable string (1024-based, 1 decimal).
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

const _kImageGif = 'image/gif';

/// Extracted chat input bar from ChatPanel (~850 lines).
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

class ChatInputBarState extends ConsumerState<ChatInputBar> {
  final _messageController = TextEditingController();
  final _inputFocusNode = FocusNode();

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

  /// Last known keyboard height -- used to size the inline picker so it
  /// occupies the same space the keyboard did.
  double _lastKeyboardHeight = 0;

  // File picker guard
  bool _isPickingFile = false;

  // Edit mode state
  ChatMessage? _editingMessage;
  bool get _isEditing => _editingMessage != null;

  // Mention autocomplete state
  bool _showMentionPicker = false;
  String _mentionQuery = '';

  // Pending attachments staged for the current send. Single-pick uses one
  // entry (with the caption-and-send flow); multi-pick stages all picked
  // files here so the user can review, cancel individual files, and watch
  // progress before sending. Each entry carries its own ValueNotifier for
  // upload progress so chip rebuilds don't ripple through the whole bar.
  final List<PendingAttachment> _pendingAttachments = [];

  bool get _hasPendingAttachment => _pendingAttachments.isNotEmpty;
  bool get _isAnyPendingAttachmentUploading =>
      _pendingAttachments.any((a) => a.isUploading);
  bool get _allPendingAttachmentsReady =>
      _pendingAttachments.isNotEmpty &&
      _pendingAttachments.every((a) => a.uploadedUrl != null);

  // Voice recording state
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;
  final List<double> _recordingAmplitudes = [];

  // Debounce for search (used by _detectMention indirectly via parent, but
  // kept here to match the cancel contract in dispose/didUpdateWidget).
  Timer? _searchDebounce;

  // Draft auto-save
  static const _draftKeyPrefix = 'chat_draft_';
  Timer? _draftSaveTimer;
  // Suppresses draft saves during cancel-edit to avoid race with _loadDraft.
  bool _suppressDraftSave = false;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(_onTextChanged);
    _loadDraft(widget.conversation.id);
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation.id != oldWidget.conversation.id) {
      // Save draft for the outgoing conversation
      _saveDraftImmediate(oldWidget.conversation.id, _messageController.text);
      _draftSaveTimer?.cancel();

      _showMentionPicker = false;
      _mentionQuery = '';
      _searchDebounce?.cancel();
      _clearPendingAttachment();
      _messageController.clear();
      _editingMessage = null;
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
    _searchDebounce?.cancel();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Public API (called by parent via GlobalKey<ChatInputBarState>)
  // ---------------------------------------------------------------------------

  void enterEditMode(ChatMessage message) {
    // Clear any active reply — editing and replying are mutually exclusive.
    ref.read(chatProvider.notifier).clearReplyTo();
    setState(() {
      _editingMessage = message;
      _messageController.text = message.content;
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
    final mimeTypes = <String, List<String>>{
      'jpg': ['image', 'jpeg'],
      'jpeg': ['image', 'jpeg'],
      'png': ['image', 'png'],
      'gif': ['image', 'gif'],
      'webp': ['image', 'webp'],
      'mp4': ['video', 'mp4'],
      'mov': ['video', 'quicktime'],
      'webm': ['video', 'webm'],
      'pdf': ['application', 'pdf'],
      'mp3': ['audio', 'mpeg'],
      'ogg': ['audio', 'ogg'],
      'wav': ['audio', 'wav'],
      'm4a': ['audio', 'mp4'],
      'aac': ['audio', 'aac'],
    };
    final mime = mimeTypes[ext] ?? ['application', _kOctetStream];

    _setPendingAttachment(
      bytes: fileBytes,
      fileName: fileName,
      mimeType: '${mime[0]}/${mime[1]}',
      ext: ext.isNotEmpty ? ext : 'bin',
    );
  }

  // ---------------------------------------------------------------------------
  // Draft auto-save
  // ---------------------------------------------------------------------------

  Future<void> _loadDraft(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix$conversationId';
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
    final key = '$_draftKeyPrefix$conversationId';
    if (text.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, text);
    }
  }

  // ---------------------------------------------------------------------------
  // Text listener
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    final text = _messageController.text;
    final empty = text.trim().isEmpty;
    // Detect multiline either via explicit newlines or content long enough
    // to soft-wrap at the current viewport width. The character threshold
    // is recomputed in build() from MediaQuery so a 4K-wide input doesn't
    // jump to multi-line halfway through a normal sentence.
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

  // ---------------------------------------------------------------------------
  // Send message
  // ---------------------------------------------------------------------------

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
    // Caption goes on the FIRST attachment so it stays attached visually;
    // the rest are bare media markers. Matches Discord / iMessage.
    if (_hasPendingAttachment && _allPendingAttachmentsReady) {
      final attachments = List<PendingAttachment>.from(_pendingAttachments);
      _clearAllPendingAttachments();
      _messageController.clear();
      _saveDraftImmediate(widget.conversation.id, '');
      for (var i = 0; i < attachments.length; i++) {
        final att = attachments[i];
        final marker = _buildMediaMarker(
          extension: att.ext,
          url: att.uploadedUrl!,
        );
        await _doSend(marker);
        if (i == 0 && caption.isNotEmpty) {
          await _doSend(caption);
        }
      }
      widget.onMessageSent();
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

    await _doSend(text);
    _messageController.clear();
    _saveDraftImmediate(widget.conversation.id, '');
    if (_showMediaPicker) setState(() => _showMediaPicker = false);
    if (_showInlinePicker) setState(() => _showInlinePicker = false);
    widget.onMessageSent();
  }

  Future<void> _doSend(String text) async {
    if (text.isEmpty) return;
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
          text,
          myUserId,
          conversationId: conv.id,
          channelId: channelId,
          replyToId: replyTo?.id,
          replyToContent: replyTo?.content,
          replyToUsername: replyTo?.fromUsername,
        );

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
              text,
              channelId: channelId,
              replyToId: replyTo?.id,
            );
      } else {
        await ref
            .read(websocketProvider.notifier)
            .sendMessage(
              peerUserId,
              text,
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

  // ---------------------------------------------------------------------------
  // Input changed / typing indicator / mention detection
  // ---------------------------------------------------------------------------

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
    final conv = widget.conversation;
    if (!conv.isGroup) {
      if (_showMentionPicker) {
        setState(() {
          _showMentionPicker = false;
          _mentionQuery = '';
        });
      }
      return;
    }

    final query = extractMentionQuery(
      text,
      _messageController.selection.baseOffset,
    );
    if (query == null) {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    setState(() {
      _showMentionPicker = true;
      _mentionQuery = query;
    });
  }

  void _handleMentionSelected(String username) {
    final text = _messageController.text;
    final cursorPos = _messageController.selection.baseOffset;

    _messageController.value = insertMention(
      text: text,
      cursorPosition: cursorPos,
      username: username,
    );

    setState(() {
      _showMentionPicker = false;
      _mentionQuery = '';
    });
    _inputFocusNode.requestFocus();
  }

  List<ConversationMember> get _filteredMentionMembers {
    final conv = widget.conversation;
    final myUserId = ref.read(authProvider).userId ?? '';
    return conv.members.where((m) => m.userId != myUserId).toList();
  }

  // ---------------------------------------------------------------------------
  // Media marker helpers
  // ---------------------------------------------------------------------------

  String _buildMediaMarker({required String extension, required String url}) {
    const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp'};
    const videoExts = {'mp4', 'webm', 'mov'};
    const audioExts = {'mp3', 'ogg', 'wav', 'm4a', 'aac'};

    final ext = extension.toLowerCase();
    if (imageExts.contains(ext)) {
      return '[img:$url]';
    }
    if (videoExts.contains(ext)) {
      return '[video:$url]';
    }
    if (audioExts.contains(ext)) {
      return '[audio:$url]';
    }
    return '[file:$url]';
  }

  String _extensionFromMime(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case _kImageGif:
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'video/mp4':
        return 'mp4';
      case 'video/webm':
        return 'webm';
      case 'video/quicktime':
        return 'mov';
      case 'application/pdf':
        return 'pdf';
      default:
        return 'bin';
    }
  }

  // ---------------------------------------------------------------------------
  // Pending attachment helpers (Discord-style preview before send)
  // ---------------------------------------------------------------------------

  /// Stage [bytes] as a new pending attachment and kick off its upload.
  /// Multiple calls accumulate — the strip shows N chips for N picks until
  /// the user sends or cancels each.
  void _setPendingAttachment({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    required String ext,
  }) {
    final attachment = PendingAttachment(
      bytes: Uint8List.fromList(bytes),
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
      sizeBytes: bytes.length,
    );
    setState(() => _pendingAttachments.add(attachment));
    _startAttachmentUploadFor(attachment);
  }

  /// Cancel and remove a single staged attachment. Safe to call before the
  /// upload completes — the [cancelled] flag short-circuits the
  /// success-path setState in [_startAttachmentUploadFor].
  void _removePendingAttachment(PendingAttachment attachment) {
    if (!_pendingAttachments.contains(attachment)) return;
    attachment.cancelled = true;
    setState(() => _pendingAttachments.remove(attachment));
    attachment.dispose();
  }

  /// Stage an external-URL attachment (e.g. picked from the GIF browser).
  /// No upload is performed — the URL is used as-is on send.
  void _setPendingExternalAttachment({
    required String url,
    required String fileName,
    required String mimeType,
    required String ext,
  }) {
    final attachment = PendingAttachment(
      bytes: null,
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
      sizeBytes: 0,
      uploadedUrl: url,
    );
    setState(() => _pendingAttachments.add(attachment));
  }

  /// Drop all staged attachments. Called after a successful send.
  void _clearAllPendingAttachments() {
    if (_pendingAttachments.isEmpty) return;
    final toDispose = List<PendingAttachment>.from(_pendingAttachments);
    setState(() => _pendingAttachments.clear());
    for (final att in toDispose) {
      att.dispose();
    }
  }

  /// Backwards-compatible no-arg clear for legacy callers (the recorder /
  /// outer error handling). Removes the most recently staged attachment.
  void _clearPendingAttachment() {
    if (_pendingAttachments.isEmpty) return;
    _removePendingAttachment(_pendingAttachments.last);
  }

  Future<void> _startAttachmentUploadFor(PendingAttachment att) async {
    if (att.isExternalUrl) return; // already has a URL (e.g. GIF picker).
    final bytes = att.bytes!;
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final result = await _uploadWithAuthRetry(
        serverUrl: serverUrl,
        bytes: bytes,
        fileName: att.fileName,
        mimeType: att.mimeType,
        onProgress: (sent, total) {
          if (att.cancelled || total <= 0) return;
          att.progress.value = (sent / total).clamp(0.0, 1.0);
        },
      );
      if (!mounted || att.cancelled) return;

      if (result != null) {
        setState(() {
          att.uploadedUrl = result;
          att.isUploading = false;
          att.progress.value = 1.0;
        });
        _inputFocusNode.requestFocus();
      } else {
        if (mounted) {
          ToastService.show(
            context,
            'Upload failed: ${att.fileName}',
            type: ToastType.error,
          );
        }
        _removePendingAttachment(att);
      }
    } catch (e) {
      if (!mounted || att.cancelled) return;
      ToastService.show(
        context,
        'Upload failed: ${att.fileName}',
        type: ToastType.error,
      );
      _removePendingAttachment(att);
    }
  }

  /// Upload media with automatic 401→token-refresh→retry.
  ///
  /// MultipartRequest streams are consumed on send, so we rebuild the request
  /// on retry rather than replaying the same object.
  /// Build a multipart upload request for the given file data.
  http.MultipartRequest _buildUploadRequest({
    required String serverUrl,
    required String token,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    void Function(int sent, int total)? onProgress,
  }) {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$serverUrl/api/media/upload'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.fields['conversation_id'] = widget.conversation.id;

    final parts = mimeType.split('/');
    final mediaType = parts.length == 2
        ? MediaType(parts[0], parts[1])
        : MediaType('application', _kOctetStream);

    if (onProgress == null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
          contentType: mediaType,
        ),
      );
    } else {
      // Wrap the byte payload in a chunked async stream so we can report
      // upload progress per chunk. The numbers reflect *stream emission*
      // rather than wire-level progress (the OS socket buffers some bytes),
      // but for files >1 MB the progress is reasonably accurate after the
      // buffer fills.
      const chunkSize = 64 * 1024;
      final total = bytes.length;
      Stream<List<int>> chunked() async* {
        var offset = 0;
        while (offset < total) {
          final end = (offset + chunkSize).clamp(0, total);
          yield bytes.sublist(offset, end);
          offset = end;
          onProgress(offset, total);
        }
      }

      request.files.add(
        http.MultipartFile(
          'file',
          chunked(),
          total,
          filename: fileName,
          contentType: mediaType,
        ),
      );
    }
    return request;
  }

  Future<String?> _uploadWithAuthRetry({
    required String serverUrl,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    // If the user has the "preserve original filenames" privacy toggle off,
    // upload the file under a generic name keyed off the extension. The file
    // contents are unchanged.
    final preserve = await readPreserveOriginalFilenames();
    final uploadFileName = preserve ? fileName : _genericFilename(fileName);

    for (var attempt = 0; attempt < 2; attempt++) {
      final token = ref.read(authProvider).token;
      if (token == null) return null;

      final request = _buildUploadRequest(
        serverUrl: serverUrl,
        token: token,
        bytes: bytes,
        fileName: uploadFileName,
        mimeType: mimeType,
        onProgress: onProgress,
      );

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(body);
        return data['url'] as String?;
      }

      if (response.statusCode == 401 && attempt == 0) {
        final refreshed = await ref
            .read(authProvider.notifier)
            .refreshAccessToken();
        if (!refreshed) return null;
        continue;
      }

      if (mounted) {
        ToastService.show(
          context,
          'Upload failed (${response.statusCode})',
          type: ToastType.error,
        );
      }
      return null;
    }
    return null;
  }

  Future<void> _pasteImageFromClipboard() async {
    final image = await readImageFromClipboard();
    if (image == null) return;
    if (!mounted) return;

    _setPendingAttachment(
      bytes: image.bytes,
      fileName: image.fileName,
      mimeType: image.mimeType,
      ext: _extensionFromMime(image.mimeType),
    );
  }

  /// Handle Ctrl+V: read clipboard text and insert at cursor, bypassing the
  /// browser's native paste context menu that CanvasKit shows by default.
  /// Also tries image paste in parallel for clipboard images.
  Future<void> _handlePaste() async {
    // Try image paste (non-blocking)
    if (!_isEditing) {
      _pasteImageFromClipboard();
    }

    // Read text from clipboard and insert at cursor
    final data = await Clipboard.getData('text/plain');
    if (data?.text == null || data!.text!.isEmpty) return;
    if (!mounted) return;

    final text = data.text!;
    final selection = _messageController.selection;
    final currentText = _messageController.text;

    if (selection.isValid) {
      final newText = currentText.replaceRange(
        selection.start,
        selection.end,
        text,
      );
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + text.length,
        ),
      );
    } else {
      _messageController.value = TextEditingValue(
        text: currentText + text,
        selection: TextSelection.collapsed(
          offset: currentText.length + text.length,
        ),
      );
    }

    _onInputChanged(_messageController.text);
  }

  // ---------------------------------------------------------------------------
  // File mime resolution (shared between pickers)
  // ---------------------------------------------------------------------------

  static const _kMimeTypes = <String, List<String>>{
    'jpg': ['image', 'jpeg'],
    'jpeg': ['image', 'jpeg'],
    'png': ['image', 'png'],
    'gif': ['image', 'gif'],
    'webp': ['image', 'webp'],
    'mp4': ['video', 'mp4'],
    'mov': ['video', 'quicktime'],
    'webm': ['video', 'webm'],
    'pdf': ['application', 'pdf'],
    'mp3': ['audio', 'mpeg'],
    'ogg': ['audio', 'ogg'],
    'wav': ['audio', 'wav'],
    'm4a': ['audio', 'mp4'],
    'aac': ['audio', 'aac'],
  };

  /// Upload [bytes] and immediately send the result as a message.
  /// Used for the 2nd..Nth files when multiple are selected at once.
  Future<void> _sendFileImmediately({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String ext,
  }) async {
    final serverUrl = ref.read(serverUrlProvider);
    final url = await _uploadWithAuthRetry(
      serverUrl: serverUrl,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    if (!mounted || url == null) return;
    final marker = _buildMediaMarker(extension: ext, url: url);
    await _doSend(marker);
  }

  Future<void> _pickFile() async {
    if (_isPickingFile) return;
    _isPickingFile = true;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      // Single pick → preview flow (caption + send). Multi pick → send all
      // immediately as separate messages; mixing the two creates races where
      // the user may interact with the pending preview while the rest are
      // still uploading in the background.
      final isMulti = result.files.length > 1;
      if (isMulti) {
        ToastService.show(
          context,
          'Sending ${result.files.length} files...',
          type: ToastType.info,
        );
      }

      var sentCount = 0;
      for (final file in result.files) {
        if (file.size > _kMaxUploadBytes) {
          if (mounted) {
            ToastService.show(
              context,
              '${file.name} is ${_formatBytes(file.size)} — limit is '
              '${_formatBytes(_kMaxUploadBytes)}',
              type: ToastType.error,
            );
          }
          continue;
        }

        // On mobile, withData:true may still yield null bytes for larger files
        // or certain content URIs. Fall back to reading from the file path.
        Uint8List? bytes = file.bytes;
        if (bytes == null && file.path != null && !kIsWeb) {
          try {
            bytes = await File(file.path!).readAsBytes();
          } catch (e) {
            debugPrint('[ChatInput] Failed to read file from path: $e');
          }
        }

        if (bytes == null) {
          if (mounted) {
            ToastService.show(
              context,
              'Could not read file: ${file.name}',
              type: ToastType.error,
            );
          }
          continue;
        }

        final ext = (file.extension ?? '').toLowerCase();
        final mime = _kMimeTypes[ext] ?? ['application', _kOctetStream];
        final mimeType = '${mime[0]}/${mime[1]}';

        if (isMulti) {
          try {
            await _sendFileImmediately(
              bytes: bytes,
              fileName: file.name,
              mimeType: mimeType,
              ext: ext,
            );
            sentCount++;
          } catch (e) {
            debugPrint('[ChatInput] Send failed for ${file.name}: $e');
            if (mounted) {
              ToastService.show(
                context,
                'Failed to send ${file.name}',
                type: ToastType.error,
              );
            }
          }
        } else {
          _setPendingAttachment(
            bytes: bytes,
            fileName: file.name,
            mimeType: mimeType,
            ext: ext,
          );
        }
      }
      if (isMulti && mounted && sentCount < result.files.length) {
        final failed = result.files.length - sentCount;
        ToastService.show(
          context,
          '$failed of ${result.files.length} failed to send',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.show(context, 'File pick error: $e', type: ToastType.error);
    } finally {
      _isPickingFile = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Edit mode
  // ---------------------------------------------------------------------------

  void _cancelEditMode() {
    _draftSaveTimer?.cancel();
    _suppressDraftSave = true;
    setState(() {
      _editingMessage = null;
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
    // #582: belt-and-suspenders for the parent UI gate. Editing on an
    // encrypted conversation would broadcast plaintext to every member, so
    // we never submit it. The server also returns 409.
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
      // The server returns 409 when an encrypted conversation rejects an
      // edit (#582). Surface a non-fatal toast so the user understands
      // why the change rolled back.
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

  // ---------------------------------------------------------------------------
  // Voice state sync (for push-to-talk key handling)
  // ---------------------------------------------------------------------------

  Future<void> _syncVoiceState() async {
    final conv = widget.conversation;
    final channelId = widget.effectiveActiveVoiceChannelId;
    if (channelId == null) return;
    final voiceSettings = ref.read(voiceSettingsProvider);
    await ref
        .read(channelsProvider.notifier)
        .updateVoiceState(
          conversationId: conv.id,
          channelId: channelId,
          isMuted: voiceSettings.selfMuted,
          isDeafened: voiceSettings.selfDeafened,
          pushToTalk: voiceSettings.pushToTalkEnabled,
        );
  }

  // ---------------------------------------------------------------------------
  // Voice recording
  // ---------------------------------------------------------------------------

  Future<void> _startRecording() async {
    if (kIsWeb) {
      // Web recording not supported via the record package in this config.
      ToastService.show(
        context,
        'Voice messages are not supported in the browser yet',
        type: ToastType.info,
      );
      return;
    }

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ToastService.show(
          context,
          'Microphone permission is required to send voice messages',
          type: ToastType.error,
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 64000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      // record's iOS / Android backends can throw on session-init failures
      // (audio session in use by another app, codec unavailable, etc.).
      // Without surfacing this, the user just saw nothing happen when they
      // tried to record (#554).
      debugPrint('[ChatInput] _recorder.start failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Could not start recording: $e',
          type: ToastType.error,
        );
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _recordingDuration = Duration.zero;
      _recordingAmplitudes.clear();
    });

    // Tick every 100ms to update the duration counter and collect amplitudes.
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) async {
      if (!_isRecording || !mounted) return;
      final elapsed = DateTime.now().difference(_recordingStartTime!);
      setState(() => _recordingDuration = elapsed);

      try {
        final amp = await _recorder.getAmplitude();
        // amp.current is in dBFS [-160, 0]. Map to [0, 1].
        final normalised = ((amp.current + 60) / 60).clamp(0.0, 1.0);
        _recordingAmplitudes.add(normalised);
      } catch (_) {
        // Amplitude polling is best-effort.
      }
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    if (!_isRecording) return;

    final path = await _recorder.stop();

    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
    });

    if (cancel || path == null) {
      _recordingAmplitudes.clear();
      return;
    }

    // Read the recorded bytes and attach as a pending voice message.
    try {
      final file = File(path);
      if (!file.existsSync()) {
        if (mounted) {
          ToastService.show(
            context,
            'Recording was lost — no audio file produced',
            type: ToastType.error,
          );
        }
        return;
      }
      final bytes = await file.readAsBytes();
      _recordingAmplitudes.clear();

      // Reject empty / near-empty recordings rather than uploading a
      // 0-byte file that the server will reject anyway. The threshold is
      // generous — even a 100ms aac frame is hundreds of bytes (#554).
      if (bytes.length < 256) {
        if (mounted) {
          ToastService.show(
            context,
            'Recording was too short or silent (${bytes.length}B)',
            type: ToastType.error,
          );
        }
        return;
      }

      _setPendingVoiceAttachment(bytes: bytes);
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Could not read recording: $e',
          type: ToastType.error,
        );
      }
    }
  }

  void _setPendingVoiceAttachment({required Uint8List bytes}) {
    final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _setPendingAttachment(
      bytes: bytes,
      fileName: fileName,
      mimeType: 'audio/mp4',
      ext: 'm4a',
    );
  }

  String _formatRecordingDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // Recording overlay shown in place of the input row while recording.
  Widget _buildRecordingRow() {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: EchoTheme.danger.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 12),
          // Pulsing red dot
          _PulsingDot(color: EchoTheme.danger),
          const SizedBox(width: 8),
          Text(
            _formatRecordingDuration(_recordingDuration),
            style: TextStyle(
              color: EchoTheme.danger,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          // Mini waveform bars (live amplitude)
          Expanded(child: _LiveWaveformBars(amplitudes: _recordingAmplitudes)),
          const SizedBox(width: 8),
          // Cancel button
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              color: context.textMuted,
              size: 20,
            ),
            tooltip: 'Cancel recording',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => _stopRecording(cancel: true),
          ),
          // Stop / send button
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: GestureDetector(
              onTap: () => _stopRecording(),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: EchoTheme.danger,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.stop_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build helpers -- kept in root widget
  // ---------------------------------------------------------------------------

  Widget _buildAttachFileButton() {
    final isMobile = Responsive.isMobile(context);
    final onTap = isMobile ? _showMobileAttachMenu : _pickFile;
    return Tooltip(
      message: isMobile ? 'Attach' : 'Attach file',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.surface,
              shape: BoxShape.circle,
              border: Border.all(color: context.border, width: 1),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.add, size: 20, color: context.textSecondary),
          ),
        ),
      ),
    );
  }

  void _showMobileAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AttachOption(
                icon: Icons.photo_library_outlined,
                label: 'Photos & Videos',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageFromGallery();
                },
              ),
              _AttachOption(
                icon: Icons.camera_alt_outlined,
                label: 'Camera',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageFromCamera();
                },
              ),
              _AttachOption(
                icon: Icons.insert_drive_file_outlined,
                label: 'File',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickImageFromGallery() async {
    if (_isPickingFile) return;
    _isPickingFile = true;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.media,
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      final isMulti = result.files.length > 1;
      if (isMulti) {
        ToastService.show(
          context,
          'Sending ${result.files.length} files...',
          type: ToastType.info,
        );
      }

      var sentCount = 0;
      for (final file in result.files) {
        if (file.size > _kMaxUploadBytes) {
          if (mounted) {
            ToastService.show(
              context,
              '${file.name} is ${_formatBytes(file.size)} — limit is '
              '${_formatBytes(_kMaxUploadBytes)}',
              type: ToastType.error,
            );
          }
          continue;
        }

        Uint8List? bytes = file.bytes;
        if (bytes == null && file.path != null && !kIsWeb) {
          try {
            bytes = await File(file.path!).readAsBytes();
          } catch (_) {}
        }
        if (bytes == null) continue;

        final ext = (file.extension ?? '').toLowerCase();
        final mime = _kMimeTypes[ext] ?? ['application', _kOctetStream];
        final mimeType = '${mime[0]}/${mime[1]}';

        if (isMulti) {
          try {
            await _sendFileImmediately(
              bytes: bytes,
              fileName: file.name,
              mimeType: mimeType,
              ext: ext,
            );
            sentCount++;
          } catch (e) {
            debugPrint('[ChatInput] Send failed for ${file.name}: $e');
            if (mounted) {
              ToastService.show(
                context,
                'Failed to send ${file.name}',
                type: ToastType.error,
              );
            }
          }
        } else {
          _setPendingAttachment(
            bytes: bytes,
            fileName: file.name,
            mimeType: mimeType,
            ext: ext,
          );
        }
      }
      if (isMulti && mounted && sentCount < result.files.length) {
        final failed = result.files.length - sentCount;
        ToastService.show(
          context,
          '$failed of ${result.files.length} failed to send',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.show(context, 'Pick error: $e', type: ToastType.error);
    } finally {
      _isPickingFile = false;
    }
  }

  Future<void> _pickImageFromCamera() async {
    if (_isPickingFile) return;
    _isPickingFile = true;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final file = result.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null && !kIsWeb) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) return;
      final ext = (file.extension ?? 'jpg').toLowerCase();
      _setPendingAttachment(
        bytes: bytes,
        fileName: file.name,
        mimeType: 'image/${ext == 'jpg' ? 'jpeg' : ext}',
        ext: ext,
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(context, 'Camera error: $e', type: ToastType.error);
    } finally {
      _isPickingFile = false;
    }
  }

  Widget _buildMediaPickerToggle({
    required bool showMediaPicker,
    required bool isMobileLayout,
  }) {
    return Semantics(
      toggled: showMediaPicker,
      label: 'Emoji picker',
      child: IconButton(
        icon: Icon(
          showMediaPicker
              ? Icons.keyboard_outlined
              : Icons.sentiment_satisfied_alt_outlined,
          size: 20,
          color: showMediaPicker ? context.accent : context.textSecondary,
        ),
        tooltip: showMediaPicker ? 'Keyboard' : 'Emoji & GIF',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () {
          if (isMobileLayout) {
            if (_showInlinePicker) {
              setState(() => _showInlinePicker = false);
              _inputFocusNode.requestFocus();
            } else {
              _inputFocusNode.unfocus();
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                if (mounted) setState(() => _showInlinePicker = true);
              });
            }
            widget.onMediaPickerChanged?.call();
          } else {
            setState(() => _showMediaPicker = !_showMediaPicker);
            widget.onMediaPickerChanged?.call();
            if (!_showMediaPicker) {
              _inputFocusNode.requestFocus();
            }
          }
        },
      ),
    );
  }

  /// Expose inline picker state for ChatPanel layout adjustments.
  bool get showInlinePicker => _showInlinePicker;

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

  /// Handles the Escape key. Returns true if the event was consumed.
  void _handleEscapeKey() {
    if (_showMentionPicker) {
      setState(() {
        _showMentionPicker = false;
        _mentionQuery = '';
      });
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

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleEscapeKey();
    }

    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _isEditing ? _submitEdit() : _sendMessage();
      return KeyEventResult.handled;
    }

    final modResult = _handleModifierShortcut(event);
    if (modResult != KeyEventResult.ignored) return modResult;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return _handleArrowUpEditLast();
    }

    return KeyEventResult.ignored;
  }

  Widget _buildTextField({
    required bool showMediaPicker,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
  }) {
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
          maxLines: 10,
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

  Widget _buildSendButton() {
    final hasContent = !_isTextEmpty || _allPendingAttachmentsReady;

    // For DMs, gate on crypto readiness so users can't send before encryption
    // is initialized (which would fail with a confusing error).
    final cryptoState = ref.watch(cryptoProvider);
    final cryptoReady =
        cryptoState.isInitialized && !cryptoState.keysUploadFailed;
    final isDm = !widget.conversation.isGroup;
    final canSend = hasContent && (cryptoReady || !isDm);

    // When there's no content and not editing, show a bordered mic button
    // (mirrors the design's RoundIcon). It transitions to the filled accent
    // send button below as soon as content is present.
    final showMic = !hasContent && !_isEditing && !kIsWeb;
    if (showMic) {
      return Semantics(
        label: 'Record voice message',
        button: true,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _startRecording,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.surface,
                shape: BoxShape.circle,
                border: Border.all(color: context.border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.mic_outlined,
                size: 20,
                color: context.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    final Color fillColor;
    if (!canSend) {
      fillColor = context.surface;
    } else if (_isEditing) {
      fillColor = EchoTheme.online;
    } else {
      fillColor = context.accent;
    }
    final iconColor = canSend ? Colors.white : context.textMuted;
    final showBorder = !canSend;

    final cryptoBlocked = isDm && !cryptoReady;

    Widget button = Semantics(
      label: _isEditing ? 'Confirm edit' : 'Send message',
      button: true,
      enabled: canSend,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: canSend ? _resolvedSendAction() : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: fillColor,
              shape: BoxShape.circle,
              border: showBorder
                  ? Border.all(color: context.border, width: 1)
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(
              _isEditing ? Icons.check_rounded : Icons.arrow_upward_rounded,
              size: 20,
              color: iconColor,
            ),
          ),
        ),
      ),
    );

    if (cryptoBlocked) {
      button = Tooltip(message: 'Encryption unavailable', child: button);
    }

    return button;
  }

  Widget _buildInputRow({
    required bool showMediaPicker,
    required bool isMobileLayout,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
  }) {
    // While recording, replace the entire input row with the recording UI.
    if (_isRecording) {
      return _buildRecordingRow();
    }

    // Three-element design: bordered round + button on the left, pill input
    // (with emoji glyph inside on the right), bordered round mic/send on
    // the right. Edit mode tints the pill border accent.
    final pillBorderColor = _isEditing ? context.accent : context.border;

    return Row(
      crossAxisAlignment: _isMultiline
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.center,
      children: [
        if (!_isEditing) _buildAttachFileButton(),
        if (!_isEditing) const SizedBox(width: 8),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.only(left: 12, right: 4),
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
                  voiceSettings: voiceSettings,
                  effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
                ),
                _buildMediaPickerToggle(
                  showMediaPicker: showMediaPicker,
                  isMobileLayout: isMobileLayout,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _buildSendButton(),
      ],
    );
  }

  /// Whether the media picker is currently shown. Exposed for ChatPanel
  /// to render the picker in its own overlay Stack.
  bool get showMediaPicker => _showMediaPicker;

  /// Build the media picker panel. Called by ChatPanel to render it
  /// above the message list (not inside the input bar's Stack).
  Widget buildMediaPickerPanel() {
    return MediaPickerPanel(
      onEmojiSelected: (category, emoji) {
        final text = _messageController.text;
        final selection = _messageController.selection;
        final cursorPos = selection.baseOffset >= 0
            ? selection.baseOffset
            : text.length;
        final newText =
            text.substring(0, cursorPos) +
            emoji.emoji +
            text.substring(cursorPos);
        _messageController.text = newText;
        final newCursor = cursorPos + emoji.emoji.length;
        _messageController.selection = TextSelection.collapsed(
          offset: newCursor,
        );
      },
      onGifSelected: (gifUrl, slug) {
        setState(() => _showMediaPicker = false);
        // GIF is an external URL -- no upload needed.
        _setPendingExternalAttachment(
          url: gifUrl,
          fileName: 'gif',
          mimeType: _kImageGif,
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
    final myUserId = ref.watch(authProvider).userId ?? '';
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final replyToMessage = ref.watch(
      chatProvider.select((s) => s.replyToMessage),
    );

    // Recompute the multiline threshold from the viewport width so the
    // input row only flips to multi-line when the message is long enough
    // to actually wrap visually.  Inter 14px averages ~7-8px/char; we
    // subtract a generous fixed budget for icons/padding (~120px), divide
    // the remainder by 8, and clamp to a sane band.
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
            // Mention autocomplete picker
            if (_showMentionPicker)
              MentionAutocomplete(
                members: _filteredMentionMembers,
                mentionQuery: _mentionQuery,
                onMentionSelected: _handleMentionSelected,
              ),
            // Input area
            Container(
              padding: EdgeInsets.fromLTRB(20, 8, 20, bottomPadding),
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
                  // Reply preview bar
                  if (replyToMessage != null)
                    ReplyPreviewBar(
                      replyToMessage: replyToMessage,
                      onDismiss: () =>
                          ref.read(chatProvider.notifier).clearReplyTo(),
                    ),
                  // Pending-attachments strip — one chip per staged file
                  // with thumbnail, name, size, progress, and cancel.
                  if (_hasPendingAttachment)
                    PendingAttachmentsStrip(
                      attachments: _pendingAttachments,
                      onCancel: _removePendingAttachment,
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
            if (isMobileLayout)
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                child: _showInlinePicker
                    ? SizedBox(
                        height: _lastKeyboardHeight > 0
                            ? _lastKeyboardHeight
                            : 280,
                        child: MobileMediaPickerPanel(
                          onEmojiSelected: (category, emoji) {
                            final text = _messageController.text;
                            final selection = _messageController.selection;
                            final cursorPos = selection.baseOffset >= 0
                                ? selection.baseOffset
                                : text.length;
                            final newText =
                                text.substring(0, cursorPos) +
                                emoji.emoji +
                                text.substring(cursorPos);
                            _messageController.text = newText;
                            _messageController.selection =
                                TextSelection.collapsed(
                                  offset: cursorPos + emoji.emoji.length,
                                );
                            _onInputChanged(newText);
                          },
                          onGifSelected: (gifUrl, slug) {
                            setState(() => _showInlinePicker = false);
                            _setPendingExternalAttachment(
                              url: gifUrl,
                              fileName: 'gif',
                              mimeType: _kImageGif,
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
              ),
          ],
        ),
        // Media picker is rendered by ChatPanel in its own Stack (above message list).
      ],
    );
  }

  /// Handle a photo selected from the camera roll gallery.
  Future<void> _handlePhotoSelected(
    File file,
    String fileName,
    String mimeType,
  ) async {
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final ext = fileName.split('.').last.toLowerCase();
    setState(() => _showInlinePicker = false);
    _setPendingAttachment(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
    );
  }
}

/// Pulsing red dot shown in the recording row to indicate active recording.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      // Respect reduced-motion accessibility preference -- show a static dot.
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      );
    }
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Live mini waveform bars that grow as amplitude samples arrive.
/// Scrolls from right to left, showing the most recent [_kDisplayCount] bars.
class _LiveWaveformBars extends StatelessWidget {
  static const _kDisplayCount = 40;

  final List<double> amplitudes;

  const _LiveWaveformBars({required this.amplitudes});

  @override
  Widget build(BuildContext context) {
    final bars = amplitudes.length > _kDisplayCount
        ? amplitudes.sublist(amplitudes.length - _kDisplayCount)
        : amplitudes;

    return SizedBox(
      height: 24,
      child: CustomPaint(
        painter: _LiveWaveformPainter(bars: bars, color: EchoTheme.danger),
      ),
    );
  }
}

class _LiveWaveformPainter extends CustomPainter {
  final List<double> bars;
  final Color color;

  const _LiveWaveformPainter({required this.bars, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const barGap = 2.0;
    final count = bars.length;
    final barWidth = (size.width - barGap * (count - 1)) / count;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final h = (bars[i] * size.height).clamp(2.0, size.height);
      final left = i * (barWidth + barGap);
      final top = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          top,
          left + barWidth,
          top + h,
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWaveformPainter old) => old.bars != bars;
}

/// A single row in the mobile attachment bottom sheet.
class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: context.textSecondary),
      title: Text(label, style: TextStyle(color: context.textPrimary)),
      onTap: onTap,
    );
  }
}
