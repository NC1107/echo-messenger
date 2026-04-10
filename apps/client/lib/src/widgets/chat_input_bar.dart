import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
import '../providers/server_url_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/clipboard_image_helper.dart';
import 'input/attachment_preview.dart';
import 'input/input_status_bar.dart';
import 'input/mention_autocomplete.dart';
import 'input/reply_preview_bar.dart';
import 'media_picker_panel.dart';
import 'mobile_media_picker_panel.dart';

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

  // Pending attachment (Discord-style preview before send)
  Uint8List? _pendingAttachmentBytes;
  String? _pendingAttachmentFileName;
  String? _pendingAttachmentMimeType;
  String? _pendingAttachmentExt;
  String? _pendingAttachmentUrl;
  bool _isUploadingAttachment = false;

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
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Public API (called by parent via GlobalKey<ChatInputBarState>)
  // ---------------------------------------------------------------------------

  void enterEditMode(ChatMessage message) {
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
    if (empty != _isTextEmpty) {
      setState(() => _isTextEmpty = empty);
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

    // If there's an uploaded attachment, send it as a separate message
    if (_pendingAttachmentUrl != null && _pendingAttachmentExt != null) {
      final marker = _buildMediaMarker(
        extension: _pendingAttachmentExt!,
        url: _pendingAttachmentUrl!,
      );
      _clearPendingAttachment();
      _messageController.clear();
      _saveDraftImmediate(widget.conversation.id, '');
      await _doSend(marker);
      // If user typed a caption, send it as a second message
      if (caption.isNotEmpty) {
        await _doSend(caption);
      }
      widget.onMessageSent();
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
    final conv = widget.conversation;
    if (text.isNotEmpty) {
      ref
          .read(websocketProvider.notifier)
          .sendTyping(
            conv.id,
            channelId: conv.isGroup ? widget.selectedTextChannelId : null,
          );
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

    final ext = extension.toLowerCase();
    if (imageExts.contains(ext)) {
      return '[img:$url]';
    }
    if (videoExts.contains(ext)) {
      return '[video:$url]';
    }
    return '[file:$url]';
  }

  String _extensionFromMime(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
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

  void _setPendingAttachment({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    required String ext,
  }) {
    setState(() {
      _pendingAttachmentBytes = Uint8List.fromList(bytes);
      _pendingAttachmentFileName = fileName;
      _pendingAttachmentMimeType = mimeType;
      _pendingAttachmentExt = ext;
      _pendingAttachmentUrl = null;
      _isUploadingAttachment = false;
    });
    _startAttachmentUpload();
  }

  void _clearPendingAttachment() {
    setState(() {
      _pendingAttachmentBytes = null;
      _pendingAttachmentFileName = null;
      _pendingAttachmentMimeType = null;
      _pendingAttachmentExt = null;
      _pendingAttachmentUrl = null;
      _isUploadingAttachment = false;
    });
  }

  Future<void> _startAttachmentUpload() async {
    final bytes = _pendingAttachmentBytes;
    final fileName = _pendingAttachmentFileName;
    final mimeType = _pendingAttachmentMimeType;
    if (bytes == null || fileName == null || mimeType == null) return;

    setState(() => _isUploadingAttachment = true);

    final serverUrl = ref.read(serverUrlProvider);

    try {
      final result = await _uploadWithAuthRetry(
        serverUrl: serverUrl,
        bytes: bytes,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (!mounted) return;

      if (result != null) {
        setState(() {
          _pendingAttachmentUrl = result;
          _isUploadingAttachment = false;
        });
        _inputFocusNode.requestFocus();
      } else {
        ToastService.show(context, 'Upload failed', type: ToastType.error);
        _clearPendingAttachment();
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.show(context, 'Upload failed: $e', type: ToastType.error);
      _clearPendingAttachment();
    }
  }

  /// Upload media with automatic 401→token-refresh→retry.
  ///
  /// MultipartRequest streams are consumed on send, so we rebuild the request
  /// on retry rather than replaying the same object.
  Future<String?> _uploadWithAuthRetry({
    required String serverUrl,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = ref.read(authProvider).token;
      if (token == null) return null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/api/media/upload'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['conversation_id'] = widget.conversation.id;

      final parts = mimeType.split('/');
      final mediaType = parts.length == 2
          ? MediaType(parts[0], parts[1])
          : MediaType('application', 'octet-stream');

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
          contentType: mediaType,
        ),
      );

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(body);
        return data['url'] as String?;
      }

      // On 401, refresh token and retry once
      if (response.statusCode == 401 && attempt == 0) {
        final refreshed = await ref
            .read(authProvider.notifier)
            .refreshAccessToken();
        if (!refreshed) return null;
        continue;
      }

      // Non-retryable failure
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

  Future<void> _pickFile() async {
    if (_isPickingFile) return;
    _isPickingFile = true;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      final file = result.files.first;
      if (file.bytes == null) {
        if (mounted) {
          ToastService.show(
            context,
            'Could not read file data',
            type: ToastType.error,
          );
        }
        return;
      }

      final ext = (file.extension ?? '').toLowerCase();
      final mimeTypes = <String, List<String>>{
        'jpg': ['image', 'jpeg'],
        'jpeg': ['image', 'jpeg'],
        'png': ['image', 'png'],
        'gif': ['image', 'gif'],
        'webp': ['image', 'webp'],
        'mp4': ['video', 'mp4'],
        'pdf': ['application', 'pdf'],
      };
      final mime = mimeTypes[ext] ?? ['application', 'octet-stream'];

      _setPendingAttachment(
        bytes: file.bytes!,
        fileName: file.name,
        mimeType: '${mime[0]}/${mime[1]}',
        ext: ext,
      );
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
    final messageId = _editingMessage!.id;
    final serverUrl = ref.read(serverUrlProvider);

    // Optimistically update local state
    ref.read(chatProvider.notifier).editMessage(conv.id, messageId, text);
    _cancelEditMode();

    try {
      await ref
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
  // Build helpers -- kept in root widget
  // ---------------------------------------------------------------------------

  Widget _buildAttachFileButton() {
    final isMobile = Responsive.isMobile(context);
    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: IconButton(
          icon: Icon(Icons.add, size: 22, color: context.textSecondary),
          tooltip: 'Attach',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: _showMobileAttachMenu,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        icon: Icon(
          Icons.attach_file_outlined,
          size: 20,
          color: context.textSecondary,
        ),
        tooltip: 'Attach file',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: _pickFile,
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final file = result.files.first;
      if (file.bytes == null) return;
      final ext = (file.extension ?? '').toLowerCase();
      final mimeTypes = <String, List<String>>{
        'jpg': ['image', 'jpeg'],
        'jpeg': ['image', 'jpeg'],
        'png': ['image', 'png'],
        'gif': ['image', 'gif'],
        'webp': ['image', 'webp'],
        'mp4': ['video', 'mp4'],
        'mov': ['video', 'quicktime'],
      };
      final mime = mimeTypes[ext] ?? ['application', 'octet-stream'];
      _setPendingAttachment(
        bytes: file.bytes!,
        fileName: file.name,
        mimeType: '${mime[0]}/${mime[1]}',
        ext: ext,
      );
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final file = result.files.first;
      if (file.bytes == null) return;
      final ext = (file.extension ?? 'jpg').toLowerCase();
      _setPendingAttachment(
        bytes: file.bytes!,
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
    return IconButton(
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
            setState(() => _showInlinePicker = true);
            _inputFocusNode.unfocus();
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
    } else if (_pendingAttachmentBytes != null ||
        _pendingAttachmentUrl != null) {
      _clearPendingAttachment();
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

    // Enter sends message, Shift+Enter for newline
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_isEditing) {
        _submitEdit();
      } else {
        _sendMessage();
      }
      return KeyEventResult.handled;
    }

    // Ctrl+V: manually handle paste to bypass browser
    // context menu on Flutter web (CanvasKit).
    final isCtrlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (event.logicalKey == LogicalKeyboardKey.keyV && isCtrlOrMeta) {
      return _handlePasteShortcut();
    }

    // Ctrl+C / Ctrl+X: handle copy/cut to prevent
    // browser context menu on selected text.
    if (event.logicalKey == LogicalKeyboardKey.keyC && isCtrlOrMeta) {
      return _handleCopyCutShortcut(false);
    }
    if (event.logicalKey == LogicalKeyboardKey.keyX && isCtrlOrMeta) {
      return _handleCopyCutShortcut(true);
    }

    // Up arrow with empty input → edit last own message (Discord behavior)
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        _isTextEmpty &&
        !_isEditing) {
      final messages = ref
          .read(chatProvider)
          .messagesForConversation(widget.conversation.id);
      final myUserId = ref.read(authProvider).userId ?? '';
      final ownMessages = messages.where(
        (m) => m.isMine && m.fromUserId == myUserId,
      );
      final lastOwn = ownMessages.isNotEmpty ? ownMessages.last : null;
      if (lastOwn != null) {
        enterEditMode(lastOwn);
        return KeyEventResult.handled;
      }
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
          autofillHints: const [],
          style: TextStyle(fontSize: 14, color: context.textPrimary),
          decoration: InputDecoration(
            hintText: _isEditing ? 'Edit your message...' : 'Type a message...',
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
    final canSend =
        !_isTextEmpty ||
        (_pendingAttachmentUrl != null && !_isUploadingAttachment);

    final Color buttonColor;
    if (!canSend) {
      buttonColor = context.textMuted;
    } else if (_isEditing) {
      buttonColor = EchoTheme.online;
    } else {
      buttonColor = context.accent;
    }

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: GestureDetector(
        onTap: canSend ? _resolvedSendAction() : null,
        child: Opacity(
          opacity: canSend ? 1 : 0.30,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: buttonColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isEditing ? Icons.check_rounded : Icons.arrow_upward_rounded,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputRow({
    required bool showMediaPicker,
    required bool isMobileLayout,
    required VoiceSettingsState voiceSettings,
    required String? effectiveActiveVoiceChannelId,
  }) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isEditing ? context.accent : context.border,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Attach file + media picker toggle (hidden in edit mode)
          if (!_isEditing) _buildAttachFileButton(),
          if (!_isEditing)
            _buildMediaPickerToggle(
              showMediaPicker: showMediaPicker,
              isMobileLayout: isMobileLayout,
            ),
          if (_isEditing) const SizedBox(width: 12),
          // Text field
          _buildTextField(
            showMediaPicker: showMediaPicker,
            voiceSettings: voiceSettings,
            effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
          ),
          // Send / confirm edit button
          _buildSendButton(),
        ],
      ),
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
        setState(() {
          _showMediaPicker = false;
          // GIF is external URL -- no upload needed, set directly
          _pendingAttachmentUrl = gifUrl;
          _pendingAttachmentExt = 'gif';
          _pendingAttachmentFileName = 'gif';
          _pendingAttachmentMimeType = 'image/gif';
          _pendingAttachmentBytes = null; // no local bytes for GIFs
          _isUploadingAttachment = false;
        });
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

  bool get _hasPendingAttachment =>
      _pendingAttachmentBytes != null || _pendingAttachmentUrl != null;

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final myUserId = ref.watch(authProvider).userId ?? '';
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final replyToMessage = ref.watch(
      chatProvider.select((s) => s.replyToMessage),
    );

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
                  // Attachment preview bar (Discord-style)
                  if (_hasPendingAttachment)
                    AttachmentPreview(
                      attachmentBytes: _pendingAttachmentBytes,
                      fileName: _pendingAttachmentFileName,
                      mimeType: _pendingAttachmentMimeType,
                      uploadedUrl: _pendingAttachmentUrl,
                      isUploading: _isUploadingAttachment,
                      onClear: _clearPendingAttachment,
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
            if (_showInlinePicker && isMobileLayout)
              SizedBox(
                height: _lastKeyboardHeight > 0 ? _lastKeyboardHeight : 280,
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
                    _messageController.selection = TextSelection.collapsed(
                      offset: cursorPos + emoji.emoji.length,
                    );
                    _onInputChanged(newText);
                  },
                  onGifSelected: (gifUrl, slug) {
                    setState(() {
                      _showInlinePicker = false;
                      _pendingAttachmentUrl = gifUrl;
                      _pendingAttachmentExt = 'gif';
                      _pendingAttachmentFileName = 'gif';
                      _pendingAttachmentMimeType = 'image/gif';
                      _pendingAttachmentBytes = null;
                      _isUploadingAttachment = false;
                    });
                  },
                  onPhotoSelected: _handlePhotoSelected,
                  onClose: () {
                    setState(() => _showInlinePicker = false);
                    _inputFocusNode.requestFocus();
                  },
                ),
              ),
          ],
        ),
        // Media picker is rendered by ChatPanel in its own Stack (above message list).
      ],
    );
  }

  /// Handle a photo selected from the camera roll gallery.
  void _handlePhotoSelected(File file, String fileName, String mimeType) {
    final bytes = file.readAsBytesSync();
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
