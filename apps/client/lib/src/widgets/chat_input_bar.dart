import 'dart:async';
import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_rtc_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/clipboard_image_helper.dart';
import 'gif_picker_widget.dart';

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

  const ChatInputBar({
    super.key,
    required this.conversation,
    this.selectedTextChannelId,
    this.effectiveActiveVoiceChannelId,
    this.typingUsers = const [],
    required this.onMessageSent,
  });

  @override
  ConsumerState<ChatInputBar> createState() => ChatInputBarState();
}

class ChatInputBarState extends ConsumerState<ChatInputBar> {
  final _messageController = TextEditingController();
  final _inputFocusNode = FocusNode();

  bool _isTextEmpty = true;
  bool _showEmojiPicker = false;
  bool _showGifPicker = false;

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

  @override
  void initState() {
    super.initState();
    _messageController.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation.id != oldWidget.conversation.id) {
      _showMentionPicker = false;
      _mentionQuery = '';
      _searchDebounce?.cancel();
      _clearPendingAttachment();
      _messageController.clear();
      _editingMessage = null;
      _isTextEmpty = true;
      _showEmojiPicker = false;
      _showGifPicker = false;
    }
  }

  @override
  void dispose() {
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

  // ---------------------------------------------------------------------------
  // Text listener
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    final empty = _messageController.text.trim().isEmpty;
    if (empty != _isTextEmpty) {
      setState(() => _isTextEmpty = empty);
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

    final conv = widget.conversation;

    // Direct messages are encrypted-only.
    if (!conv.isGroup && !conv.isEncrypted) {
      ToastService.show(
        context,
        'This direct conversation is not encrypted yet. Sending is blocked.',
        type: ToastType.warning,
      );
      return;
    }

    await _doSend(text);
    _messageController.clear();
    if (_showEmojiPicker) setState(() => _showEmojiPicker = false);
    widget.onMessageSent();
  }

  Future<void> _doSend(String text) async {
    if (text.isEmpty) return;
    final conv = widget.conversation;
    final myUserId = ref.read(authProvider).userId ?? '';

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
        );

    try {
      if (conv.isGroup) {
        await ref
            .read(websocketProvider.notifier)
            .sendGroupMessage(conv.id, text, channelId: channelId);
      } else {
        await ref
            .read(websocketProvider.notifier)
            .sendMessage(peerUserId, text, conversationId: conv.id);
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

  /// Attempts to extract a partial mention query from [text] at the cursor
  /// position. Returns the query string (lowercased, possibly empty) when an
  /// active `@` trigger is found, or `null` when no mention autocomplete
  /// should be shown.
  String? _extractMentionQuery(String text) {
    final cursorPos = _messageController.selection.baseOffset;
    if (cursorPos < 0 || cursorPos > text.length) return null;

    final beforeCursor = text.substring(0, cursorPos);
    final atIndex = beforeCursor.lastIndexOf('@');
    if (atIndex < 0) return null;

    if (atIndex > 0 && beforeCursor[atIndex - 1] != ' ') return null;

    final partial = beforeCursor.substring(atIndex + 1);
    if (partial.contains(' ')) return null;

    return partial.toLowerCase();
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

    final query = _extractMentionQuery(text);
    if (query == null) {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    setState(() {
      _showMentionPicker = true;
      _mentionQuery = query;
    });
  }

  void _insertMention(String username) {
    final text = _messageController.text;
    final cursorPos = _messageController.selection.baseOffset;
    if (cursorPos < 0) return;

    final beforeCursor = text.substring(0, cursorPos);
    final atIndex = beforeCursor.lastIndexOf('@');
    if (atIndex < 0) return;

    final afterCursor = text.substring(cursorPos);
    final replacement = '@$username ';
    final newText = text.substring(0, atIndex) + replacement + afterCursor;
    final newCursorPos = atIndex + replacement.length;

    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
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
    return conv.members.where((m) {
      if (m.userId == myUserId) return false;
      if (_mentionQuery.isEmpty) return true;
      return m.username.toLowerCase().startsWith(_mentionQuery);
    }).toList();
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
    final token = ref.read(authProvider).token;
    if (token == null) {
      _clearPendingAttachment();
      return;
    }

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/api/media/upload'),
      );
      request.headers['Authorization'] = 'Bearer $token';

      final conversationId = widget.conversation.id;
      request.fields['conversation_id'] = conversationId;

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
      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(body);
        final mediaUrl = data['url'] as String?;
        if (mediaUrl != null) {
          setState(() {
            _pendingAttachmentUrl = mediaUrl;
            _isUploadingAttachment = false;
          });
          _inputFocusNode.requestFocus();
        } else {
          ToastService.show(context, 'Upload failed', type: ToastType.error);
          _clearPendingAttachment();
        }
      } else {
        ToastService.show(
          context,
          'Upload failed (${response.statusCode})',
          type: ToastType.error,
        );
        _clearPendingAttachment();
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.show(context, 'Upload failed: $e', type: ToastType.error);
      _clearPendingAttachment();
    }
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
    setState(() {
      _editingMessage = null;
      _messageController.clear();
      _isTextEmpty = true;
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
  // Build helpers -- extracted to reduce cognitive complexity
  // ---------------------------------------------------------------------------

  Widget _buildMentionAutocomplete() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border.all(color: context.border),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        reverse: true,
        padding: EdgeInsets.zero,
        itemCount: _filteredMentionMembers.length,
        itemBuilder: (context, i) {
          final member = _filteredMentionMembers[i];
          return _buildMentionItem(member);
        },
      ),
    );
  }

  Widget _buildMentionItem(ConversationMember member) {
    return InkWell(
      onTap: () => _insertMention(member.username),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.alternate_email, size: 14, color: context.accent),
            const SizedBox(width: 8),
            Text(
              member.username,
              style: TextStyle(
                fontSize: 13,
                color: context.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (member.role != null) ...[
              const SizedBox(width: 6),
              Text(
                member.role!,
                style: TextStyle(fontSize: 11, color: context.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInputStatusBar(String inputStatusText) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _isEditing
            ? context.accent.withValues(alpha: 0.12)
            : context.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _isEditing
              ? context.accent.withValues(alpha: 0.4)
              : context.border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _isEditing ? Icons.edit_outlined : Icons.more_horiz_rounded,
            size: 12,
            color: _isEditing ? context.accent : context.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              inputStatusText,
              style: TextStyle(
                fontSize: 12,
                fontStyle: _isEditing ? FontStyle.normal : FontStyle.italic,
                color: _isEditing ? context.accent : context.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isEditing)
            GestureDetector(
              onTap: _cancelEditMode,
              child: Icon(Icons.close, size: 14, color: context.textMuted),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentThumbnail() {
    if (_pendingAttachmentBytes != null) {
      return Image.memory(
        _pendingAttachmentBytes!,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, e, st) => Container(
          width: 48,
          height: 48,
          color: context.mainBg,
          child: Icon(
            Icons.insert_drive_file_outlined,
            color: context.textMuted,
            size: 24,
          ),
        ),
      );
    }
    return Container(
      width: 48,
      height: 48,
      color: context.mainBg,
      child: Icon(Icons.gif_box_outlined, color: context.accent, size: 24),
    );
  }

  Widget _buildAttachmentStatusText() {
    final String statusLabel;
    final Color statusColor;

    if (_isUploadingAttachment) {
      statusLabel = 'Uploading...';
      statusColor = context.textMuted;
    } else if (_pendingAttachmentUrl != null) {
      statusLabel = 'Ready to send';
      statusColor = EchoTheme.online;
    } else {
      statusLabel = 'Preparing...';
      statusColor = context.textMuted;
    }

    return Text(
      statusLabel,
      style: TextStyle(fontSize: 11, color: statusColor),
    );
  }

  Widget _buildAttachmentTrailingWidgets() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isUploadingAttachment)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.accent,
            ),
          )
        else if (_pendingAttachmentUrl != null)
          Icon(Icons.check_circle_outline, size: 16, color: EchoTheme.online),
        const SizedBox(width: 6),
        // Remove button
        GestureDetector(
          onTap: _clearPendingAttachment,
          child: Icon(Icons.close, size: 16, color: context.textMuted),
        ),
      ],
    );
  }

  Widget _buildAttachmentPreview() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.border, width: 1),
      ),
      child: Row(
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _buildAttachmentThumbnail(),
          ),
          const SizedBox(width: 10),
          // Filename + status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _pendingAttachmentFileName ?? 'Attachment',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                _buildAttachmentStatusText(),
              ],
            ),
          ),
          _buildAttachmentTrailingWidgets(),
        ],
      ),
    );
  }

  Widget _buildPlusMenuButton({
    required bool showEmojiPicker,
    required bool isMobileLayout,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: PopupMenuButton<String>(
        icon: Icon(
          showEmojiPicker ? Icons.keyboard_outlined : Icons.add_circle_outline,
          size: 20,
          color: showEmojiPicker ? context.accent : context.textSecondary,
        ),
        tooltip: 'Attach or emoji',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onSelected: (value) {
          _handlePlusMenuSelection(value, showEmojiPicker);
        },
        itemBuilder: (context) => _buildPlusMenuItems(
          showEmojiPicker: showEmojiPicker,
          isMobileLayout: isMobileLayout,
        ),
      ),
    );
  }

  void _handlePlusMenuSelection(String value, bool showEmojiPicker) {
    switch (value) {
      case 'file':
        _pickFile();
      case 'emoji':
        setState(() {
          _showEmojiPicker = !_showEmojiPicker;
          _showGifPicker = false;
        });
        if (!_showEmojiPicker) {
          _inputFocusNode.requestFocus();
        }
      case 'gif':
        setState(() {
          _showGifPicker = !_showGifPicker;
          _showEmojiPicker = false;
        });
    }
  }

  List<PopupMenuEntry<String>> _buildPlusMenuItems({
    required bool showEmojiPicker,
    required bool isMobileLayout,
  }) {
    return [
      const PopupMenuItem(
        value: 'file',
        child: Row(
          children: [
            Icon(Icons.attach_file_outlined, size: 18),
            SizedBox(width: 8),
            Text('File'),
          ],
        ),
      ),
      if (!isMobileLayout)
        PopupMenuItem(
          value: 'emoji',
          child: Row(
            children: [
              Icon(
                showEmojiPicker
                    ? Icons.keyboard_outlined
                    : Icons.sentiment_satisfied_alt_outlined,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(showEmojiPicker ? 'Keyboard' : 'Emoji'),
            ],
          ),
        ),
      const PopupMenuItem(
        value: 'gif',
        child: Row(
          children: [
            Icon(Icons.gif_box_outlined, size: 18),
            SizedBox(width: 8),
            Text('GIF'),
          ],
        ),
      ),
    ];
  }

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
    } else if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _inputFocusNode.requestFocus();
    } else if (_showGifPicker) {
      setState(() => _showGifPicker = false);
      _inputFocusNode.requestFocus();
    } else if (_pendingAttachmentBytes != null ||
        _pendingAttachmentUrl != null) {
      _clearPendingAttachment();
    } else if (_isEditing) {
      _cancelEditMode();
    }
  }

  /// Handles Ctrl+V paste shortcut. Returns a [KeyEventResult] indicating
  /// whether the event was consumed.
  KeyEventResult _handlePasteShortcut() {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) {
      return KeyEventResult.ignored;
    }
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

    return KeyEventResult.ignored;
  }

  Widget _buildTextField({
    required bool showEmojiPicker,
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
          maxLines: 5,
          minLines: 1,
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
            if (showEmojiPicker) {
              setState(() => _showEmojiPicker = false);
            }
          },
          onSubmitted: (_) => _isEditing ? _submitEdit() : _sendMessage(),
        ),
      ),
    );
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
      padding: const EdgeInsets.only(right: 7),
      child: GestureDetector(
        onTap: canSend ? (_isEditing ? _submitEdit : _sendMessage) : null,
        child: Opacity(
          opacity: canSend ? 1 : 0.45,
          child: Container(
            width: 30,
            height: 30,
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
    );
  }

  Widget _buildInputRow({
    required bool showEmojiPicker,
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
          // Consolidated + button (hidden in edit mode)
          if (!_isEditing)
            _buildPlusMenuButton(
              showEmojiPicker: showEmojiPicker,
              isMobileLayout: isMobileLayout,
            ),
          if (_isEditing) const SizedBox(width: 12),
          // Text field
          _buildTextField(
            showEmojiPicker: showEmojiPicker,
            voiceSettings: voiceSettings,
            effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
          ),
          // Send / confirm edit button
          _buildSendButton(),
        ],
      ),
    );
  }

  Widget _buildEmojiPickerPanel({
    required double height,
    required int columns,
    required double emojiSize,
  }) {
    return Container(
      height: height,
      color: context.surface,
      child: EmojiPicker(
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
        config: Config(
          height: height,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            backgroundColor: context.surface,
            columns: columns,
            emojiSizeMax: emojiSize,
            noRecents: Text(
              'No recents yet. Pick one below.',
              style: TextStyle(fontSize: 14, color: context.textMuted),
            ),
          ),
          categoryViewConfig: CategoryViewConfig(
            initCategory: Category.SMILEYS,
            recentTabBehavior: RecentTabBehavior.NONE,
            backgroundColor: context.surface,
            indicatorColor: context.accent,
            iconColorSelected: context.accent,
            iconColor: context.textMuted,
          ),
          bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
          searchViewConfig: SearchViewConfig(
            backgroundColor: context.surface,
            buttonIconColor: context.textSecondary,
            hintText: 'Search emoji...',
          ),
        ),
      ),
    );
  }

  Widget _buildGifPickerPanel() {
    return GifPickerWidget(
      onClose: () => setState(() => _showGifPicker = false),
      onGifSelected: (gifUrl, slug) {
        setState(() {
          _showGifPicker = false;
          // GIF is external URL -- no upload needed, set directly
          _pendingAttachmentUrl = gifUrl;
          _pendingAttachmentExt = 'gif';
          _pendingAttachmentFileName = 'gif';
          _pendingAttachmentMimeType = 'image/gif';
          _pendingAttachmentBytes = null; // no local bytes for GIFs
          _isUploadingAttachment = false;
        });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  String _computeInputStatusText(String typingText) {
    if (_isEditing && widget.typingUsers.isNotEmpty) {
      return 'Editing message \u2022 $typingText';
    }
    if (_isEditing) return 'Editing message...';
    return typingText;
  }

  String _computeTypingText(String displayName) {
    final typingUsers = widget.typingUsers;
    if (!widget.conversation.isGroup) return '$displayName is typing...';
    if (typingUsers.length == 1) return '${typingUsers.first} is typing...';
    return '${typingUsers.join(", ")} are typing...';
  }

  bool get _hasPendingAttachment =>
      _pendingAttachmentBytes != null || _pendingAttachmentUrl != null;

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final myUserId = ref.watch(authProvider).userId ?? '';
    final voiceSettings = ref.watch(voiceSettingsProvider);

    final displayName = conv.displayName(myUserId);
    final typingText = _computeTypingText(displayName);
    final showInputStatus = _isEditing || widget.typingUsers.isNotEmpty;
    final inputStatusText = _computeInputStatusText(typingText);
    final viewportWidth = MediaQuery.of(context).size.width;
    final isMobileLayout = viewportWidth < 600;
    final isDesktopLayout = viewportWidth >= 900;
    final showEmojiPicker = _showEmojiPicker && !isMobileLayout;
    final emojiPickerHeight = isDesktopLayout ? 160.0 : 180.0;
    final emojiColumns = isDesktopLayout ? 9 : 8;
    final emojiSize = isDesktopLayout ? 24.0 : 28.0;

    final effectiveActiveVoiceChannelId = widget.effectiveActiveVoiceChannelId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Mention autocomplete picker
        if (_showMentionPicker && _filteredMentionMembers.isNotEmpty)
          _buildMentionAutocomplete(),
        // Input area
        Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          color: context.chatBg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showInputStatus) _buildInputStatusBar(inputStatusText),
              // Attachment preview bar (Discord-style)
              if (_hasPendingAttachment) _buildAttachmentPreview(),
              _buildInputRow(
                showEmojiPicker: showEmojiPicker,
                isMobileLayout: isMobileLayout,
                voiceSettings: voiceSettings,
                effectiveActiveVoiceChannelId: effectiveActiveVoiceChannelId,
              ),
            ],
          ),
        ),
        // Emoji picker panel
        if (showEmojiPicker)
          _buildEmojiPickerPanel(
            height: emojiPickerHeight,
            columns: emojiColumns,
            emojiSize: emojiSize,
          ),
        // GIF picker panel
        if (_showGifPicker) _buildGifPickerPanel(),
      ],
    );
  }
}
