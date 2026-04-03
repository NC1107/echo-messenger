import 'dart:async';
import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/chat_message.dart';
import '../models/channel.dart';
import '../models/conversation.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_rtc_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/sound_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'gif_picker_widget.dart';
import '../utils/clipboard_image_helper.dart';
import 'conversation_panel.dart' show buildAvatar, groupAvatarColor;
import 'message_item.dart';

class ChatPanel extends ConsumerStatefulWidget {
  final Conversation? conversation;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final bool hideVoiceDock;

  const ChatPanel({
    super.key,
    this.conversation,
    this.onMembersToggle,
    this.onGroupInfo,
    this.hideVoiceDock = false,
  });

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();

  bool _isTextEmpty = true;
  bool _showEmojiPicker = false;
  bool _showGifPicker = false;
  bool _hideEncryptionBanner = false;
  String? _selectedTextChannelId;
  String? _activeVoiceChannelId;
  String? _loadedHistoryKey;
  String? _loadedChannelsConversationId;

  // File picker guard
  bool _isPickingFile = false;

  // Edit mode state
  ChatMessage? _editingMessage;
  bool get _isEditing => _editingMessage != null;

  // Mention autocomplete state
  bool _showMentionPicker = false;
  String _mentionQuery = '';

  // Search state
  bool _showSearch = false;
  String _searchQuery = '';
  List<ChatMessage> _searchResults = const [];
  String? _highlightedMessageId;
  Timer? _searchDebounce;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation?.id != oldWidget.conversation?.id) {
      if (_activeVoiceChannelId != null) {
        ref.read(voiceRtcProvider.notifier).leaveChannel();
      }
      _hideEncryptionBanner = false;
      _selectedTextChannelId = null;
      _activeVoiceChannelId = null;
      _loadedHistoryKey = null;
      _showMentionPicker = false;
      _mentionQuery = '';
      _showSearch = false;
      _searchQuery = '';
      _searchResults = const [];
      _highlightedMessageId = null;
      _searchDebounce?.cancel();
      _highlightTimer?.cancel();
      _loadHistory();
      _loadChannels();
      _markAsRead();
    }
  }

  @override
  void dispose() {
    if (_activeVoiceChannelId != null) {
      ref.read(voiceRtcProvider.notifier).leaveChannel();
    }
    _searchDebounce?.cancel();
    _highlightTimer?.cancel();
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  bool _isSystemTimelineMessage(ChatMessage msg) {
    return msg.fromUserId == '__system__' &&
        (msg.content == 'encryption_enabled' ||
            msg.content == 'encryption_disabled');
  }

  Widget _buildSystemTimelineMessage(ChatMessage msg) {
    final enabled = msg.content == 'encryption_enabled';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: context.border, thickness: 1)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: context.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  enabled ? Icons.lock_outline : Icons.lock_open_outlined,
                  size: 12,
                  color: enabled ? EchoTheme.online : context.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  enabled ? 'Encryption enabled' : 'Encryption disabled',
                  style: TextStyle(
                    fontSize: 11,
                    color: enabled ? EchoTheme.online : context.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: context.border, thickness: 1)),
        ],
      ),
    );
  }

  void _onTextChanged() {
    final empty = _messageController.text.trim().isEmpty;
    if (empty != _isTextEmpty) {
      setState(() => _isTextEmpty = empty);
    }
  }

  void _loadHistory() {
    final conv = widget.conversation;
    if (conv == null) return;

    final channelId = conv.isGroup ? _selectedTextChannelId : null;
    final historyKey = '${conv.id}:${channelId ?? ''}';
    if (_loadedHistoryKey == historyKey) return;

    _loadedHistoryKey = historyKey;

    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    final cryptoState = ref.read(cryptoProvider);
    final crypto = cryptoState.isInitialized
        ? ref.read(cryptoServiceProvider)
        : null;
    if (crypto != null) {
      crypto.setToken(auth.token!);
    }

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: channelId,
          crypto: crypto,
          isGroup: conv.isGroup,
        );
  }

  Future<void> _loadChannels() async {
    final conv = widget.conversation;
    if (conv == null || !conv.isGroup) return;
    if (_loadedChannelsConversationId == conv.id) return;

    _loadedChannelsConversationId = conv.id;
    await ref.read(channelsProvider.notifier).loadChannels(conv.id);
  }

  Future<void> _syncVoiceState() async {
    final conv = widget.conversation;
    if (conv == null) return;
    final channelId = _activeVoiceChannelId;
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

  void _markAsRead() {
    final conv = widget.conversation;
    if (conv == null) return;

    ref.read(conversationsProvider.notifier).markAsRead(conv.id);

    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) {
      return;
    }

    ref.read(conversationsProvider.notifier).sendReadReceipt(conv.id);
    ref.read(websocketProvider.notifier).sendReadReceipt(conv.id);
  }

  void _onScroll() {
    if (_scrollController.position.pixels <=
        _scrollController.position.minScrollExtent + 50) {
      _loadOlderMessages();
    }
  }

  void _loadOlderMessages() {
    final conv = widget.conversation;
    if (conv == null) return;

    final channels = ref.read(channelsProvider).channelsFor(conv.id);
    final defaultTextChannelId = channels
        .where((c) => c.isText)
        .firstOrNull
        ?.id;
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled =
        conv.isGroup &&
        selectedChannelId != null &&
        selectedChannelId == defaultTextChannelId;

    final chatState = ref.read(chatProvider);
    if (chatState.isLoadingHistory(conv.id, channelId: selectedChannelId)) {
      return;
    }
    if (!chatState.conversationHasMore(conv.id, channelId: selectedChannelId)) {
      return;
    }

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: selectedChannelId,
            includeUnchanneled: includeUnchanneled,
          )
        : chatState.messagesForConversation(conv.id);
    if (messages.isEmpty) return;

    final oldestTimestamp = messages.first.timestamp;
    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    final cryptoState = ref.read(cryptoProvider);
    final crypto = cryptoState.isInitialized
        ? ref.read(cryptoServiceProvider)
        : null;
    if (crypto != null) {
      crypto.setToken(auth.token!);
    }

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: selectedChannelId,
          before: oldestTimestamp,
          crypto: crypto,
          isGroup: conv.isGroup,
        );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final conv = widget.conversation;
    if (conv == null) return;

    final myUserId = ref.read(authProvider).userId ?? '';

    // Find peer user ID for DMs
    String peerUserId = '';
    String? channelId;
    if (!conv.isGroup) {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      peerUserId = peer?.userId ?? '';

      final privacy = ref.read(privacyProvider);
      if (!conv.isEncrypted && !privacy.allowUnencryptedDm) {
        ToastService.show(
          context,
          'Plaintext direct messages are disabled in Privacy settings',
          type: ToastType.warning,
        );
        return;
      }
    } else {
      final channels = ref.read(channelsProvider).channelsFor(conv.id);
      channelId =
          _selectedTextChannelId ??
          channels.where((c) => c.isText).firstOrNull?.id;
      if (channelId == null) {
        ToastService.show(
          context,
          'No text channel available in this group',
          type: ToastType.warning,
        );
        return;
      }
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
    _messageController.clear();
    if (_showEmojiPicker) setState(() => _showEmojiPicker = false);
    _scrollToBottom();
    SoundService().playMessageSent();

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

  void _onInputChanged(String text) {
    final conv = widget.conversation;
    if (conv != null && text.isNotEmpty) {
      ref
          .read(websocketProvider.notifier)
          .sendTyping(
            conv.id,
            channelId: conv.isGroup ? _selectedTextChannelId : null,
          );
    }
    _detectMention(text);
  }

  void _detectMention(String text) {
    final conv = widget.conversation;
    if (conv == null || !conv.isGroup) {
      if (_showMentionPicker) {
        setState(() {
          _showMentionPicker = false;
          _mentionQuery = '';
        });
      }
      return;
    }

    final cursorPos = _messageController.selection.baseOffset;
    if (cursorPos < 0 || cursorPos > text.length) {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    final beforeCursor = text.substring(0, cursorPos);
    final atIndex = beforeCursor.lastIndexOf('@');
    if (atIndex < 0) {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    if (atIndex > 0 && beforeCursor[atIndex - 1] != ' ') {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    final partial = beforeCursor.substring(atIndex + 1);
    if (partial.contains(' ')) {
      if (_showMentionPicker) setState(() => _showMentionPicker = false);
      return;
    }

    setState(() {
      _showMentionPicker = true;
      _mentionQuery = partial.toLowerCase();
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
    if (conv == null) return const [];
    final myUserId = ref.read(authProvider).userId ?? '';
    return conv.members.where((m) {
      if (m.userId == myUserId) return false;
      if (_mentionQuery.isEmpty) return true;
      return m.username.toLowerCase().startsWith(_mentionQuery);
    }).toList();
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchQuery = '';
        _searchResults = const [];
        _highlightedMessageId = null;
        _searchDebounce?.cancel();
      }
    });
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = const [];
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    final conv = widget.conversation;
    if (conv == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    final myUserId = ref.read(authProvider).userId ?? '';

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/conversations/${conv.id}/search'
                '?q=${Uri.encodeQueryComponent(query)}',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        setState(() {
          _searchQuery = query;
          _searchResults = list
              .map(
                (e) => ChatMessage.fromServerJson(
                  e as Map<String, dynamic>,
                  myUserId,
                ),
              )
              .toList();
        });
      } else {
        setState(() {
          _searchQuery = query;
          _searchResults = const [];
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchQuery = query;
        _searchResults = const [];
      });
    }
  }

  void _highlightMessage(String messageId) {
    _highlightTimer?.cancel();
    setState(() {
      _highlightedMessageId = messageId;
      _showSearch = false;
      _searchQuery = '';
      _searchResults = const [];
    });
    _scrollToMessage(messageId);
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  void _scrollToMessage(String messageId) {
    final conv = widget.conversation;
    if (conv == null) return;

    final chatState = ref.read(chatProvider);
    final selChId = conv.isGroup ? _selectedTextChannelId : null;
    final channels = ref.read(channelsProvider).channelsFor(conv.id);
    final defaultTxtChId = channels.where((c) => c.isText).firstOrNull?.id;
    final inclUnchanneled =
        conv.isGroup && selChId != null && selChId == defaultTxtChId;

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: selChId,
            includeUnchanneled: inclUnchanneled,
          )
        : chatState.messagesForConversation(conv.id);

    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0 || !_scrollController.hasClients) return;

    final estimatedOffset = (index + 1) * 60.0;
    final maxExtent = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      estimatedOffset.clamp(0.0, maxExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

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

  Future<void> _uploadAndSendMedia({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    required String extension,
  }) async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (token == null) return;

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$serverUrl/api/media/upload'),
    );
    request.headers['Authorization'] = 'Bearer $token';

    final conversationId = widget.conversation?.id;
    if (conversationId != null) {
      request.fields['conversation_id'] = conversationId;
    }

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
        _messageController.text = _buildMediaMarker(
          extension: extension,
          url: mediaUrl,
        );
        _sendMessage();
      } else {
        ToastService.show(
          context,
          'Upload succeeded but no URL returned',
          type: ToastType.error,
        );
      }
    } else {
      ToastService.show(
        context,
        'Upload failed (${response.statusCode})',
        type: ToastType.error,
      );
    }
  }

  Future<void> _pasteImageFromClipboard() async {
    final conv = widget.conversation;
    if (conv == null) return;

    final image = await readImageFromClipboard();
    if (image == null) {
      return;
    }

    if (!mounted) return;
    ToastService.show(
      context,
      'Uploading pasted image...',
      type: ToastType.info,
    );

    try {
      final ext = _extensionFromMime(image.mimeType);
      await _uploadAndSendMedia(
        bytes: image.bytes,
        fileName: image.fileName,
        mimeType: image.mimeType,
        extension: ext,
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Clipboard upload failed: $e',
        type: ToastType.error,
      );
    }
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

      // Determine MIME type from file extension
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

      await _uploadAndSendMedia(
        bytes: file.bytes!,
        fileName: file.name,
        mimeType: '${mime[0]}/${mime[1]}',
        extension: ext,
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'File upload error: $e',
        type: ToastType.error,
      );
    } finally {
      _isPickingFile = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _withinTwoMinutes(String ts1, String ts2) {
    try {
      final dt1 = DateTime.parse(ts1);
      final dt2 = DateTime.parse(ts2);
      return dt2.difference(dt1).inMinutes.abs() < 2;
    } catch (_) {
      return false;
    }
  }

  bool _differentDay(String ts1, String ts2) {
    try {
      final dt1 = DateTime.parse(ts1).toLocal();
      final dt2 = DateTime.parse(ts2).toLocal();
      return dt1.year != dt2.year ||
          dt1.month != dt2.month ||
          dt1.day != dt2.day;
    } catch (_) {
      return false;
    }
  }

  Widget _buildDateDivider(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final messageDay = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(messageDay).inDays;

      String label;
      if (diff == 0) {
        label = 'Today';
      } else if (diff == 1) {
        label = 'Yesterday';
      } else {
        const months = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        label = '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
        child: Row(
          children: [
            Expanded(child: Divider(color: context.border, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.textMuted,
                ),
              ),
            ),
            Expanded(child: Divider(color: context.border, thickness: 1)),
          ],
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _buildEncryptionBanner(bool isGroup, {bool isEncrypted = false}) {
    if (_hideEncryptionBanner) {
      return const SizedBox.shrink();
    }

    final encrypted = !isGroup && isEncrypted;
    final String label;
    if (isGroup) {
      label = 'Group messages are not encrypted';
    } else if (isEncrypted) {
      label = 'Messages are end-to-end encrypted';
    } else {
      label = 'Encryption is off -- messages are sent as plaintext';
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border.all(
          color: encrypted
              ? EchoTheme.online.withValues(alpha: 0.45)
              : context.border,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            encrypted ? Icons.lock_outlined : Icons.lock_open_outlined,
            size: 14,
            color: encrypted ? EchoTheme.online : context.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: encrypted ? 12 : 11,
                color: encrypted ? EchoTheme.online : context.textMuted,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _hideEncryptionBanner = true),
            child: Icon(Icons.close, size: 14, color: context.textMuted),
          ),
        ],
      ),
    );
  }

  void _enterEditMode(ChatMessage message) {
    setState(() {
      _editingMessage = message;
      _messageController.text = message.content;
      _isTextEmpty = false;
    });
    _inputFocusNode.requestFocus();
  }

  void _cancelEditMode() {
    setState(() {
      _editingMessage = null;
      _messageController.clear();
      _isTextEmpty = true;
    });
  }

  Future<void> _toggleEncryption(Conversation conv) async {
    final newValue = !conv.isEncrypted;
    final myUserId = ref.read(authProvider).userId ?? '';
    final serverUrl = ref.read(serverUrlProvider);

    // Pre-check: warn if peer has no encryption keys when enabling.
    if (newValue && !conv.isGroup) {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      if (peer != null) {
        final crypto = ref.read(cryptoServiceProvider);
        crypto.setToken(ref.read(authProvider).token ?? '');
        final ready = await crypto.canEstablishSession(peer.userId);
        if (!ready && mounted) {
          ToastService.show(
            context,
            'Peer has not set up encryption keys yet',
            type: ToastType.warning,
          );
        }
      }
    }

    try {
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.put(
              Uri.parse('$serverUrl/api/conversations/${conv.id}/encryption'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'is_encrypted': newValue}),
            ),
          );
      // Update local conversation state
      ref
          .read(conversationsProvider.notifier)
          .updateEncryption(conv.id, newValue);
      ref
          .read(chatProvider.notifier)
          .addSystemEvent(
            conv.id,
            newValue ? 'encryption_enabled' : 'encryption_disabled',
          );
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to toggle encryption',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _resetPeerKeys(Conversation conv, String myUserId) async {
    final peerId = conv.members
        .where((m) => m.userId != myUserId)
        .firstOrNull
        ?.userId;
    if (peerId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Reset encryption keys?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will establish a fresh encrypted session. '
          'Messages encrypted with the old keys may become unreadable.',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Reset Keys'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final crypto = ref.read(cryptoServiceProvider);
      crypto.setToken(ref.read(authProvider).token ?? '');
      await crypto.invalidateSessionKey(peerId);
      if (mounted) {
        ToastService.show(
          context,
          'Encryption keys reset. Next message will establish new session.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to reset keys: $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _submitEdit() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _editingMessage == null) return;

    final conv = widget.conversation;
    if (conv == null) return;

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

  Future<void> _confirmDelete(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Delete this message?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This action cannot be undone.',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final conv = widget.conversation;
    if (conv == null) return;

    final serverUrl = ref.read(serverUrlProvider);

    // Optimistically remove from local state
    ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);

    try {
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/messages/${message.id}'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to delete message',
          type: ToastType.error,
        );
      }
    }
  }

  void _showReactionPicker(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    // Position popup near the center-top of the chat area
    final size = renderBox?.size ?? Size.zero;
    final offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final centerX = offset.dx + size.width / 2 - 160;
    final centerY = offset.dy + size.height / 2 - 40;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // Dismiss on tap outside
          Positioned.fill(
            child: GestureDetector(
              onTap: () => entry.remove(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: centerX.clamp(8.0, size.width - 330),
            top: centerY.clamp(8.0, double.infinity),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: context.surface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: reactionEmojis.map((emoji) {
                    final alreadyReacted = message.reactions.any(
                      (r) => r.emoji == emoji && r.userId == myUserId,
                    );
                    return GestureDetector(
                      onTap: () {
                        entry.remove();
                        _toggleReaction(message, emoji, alreadyReacted);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: alreadyReacted
                              ? context.accent.withValues(alpha: 0.2)
                              : null,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
  }

  Widget _buildTextChannelChip(GroupChannel channel) {
    final isSelected = _selectedTextChannelId == channel.id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() {
            _selectedTextChannelId = channel.id;
            _loadedHistoryKey = null;
          });
          _loadHistory();
          _markAsRead();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected
                  ? context.accent.withValues(alpha: 0.18)
                  : context.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isSelected
                    ? context.accent.withValues(alpha: 0.6)
                    : context.border,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tag, size: 13, color: context.textSecondary),
                const SizedBox(width: 5),
                Text(
                  channel.name,
                  style: TextStyle(
                    color: isSelected ? context.accent : context.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceChannelChip(
    String conversationId,
    GroupChannel channel,
    int participantCount,
    VoiceSettingsState voiceSettings,
    String? effectiveActiveVoiceChannelId,
  ) {
    final isActive = effectiveActiveVoiceChannelId == channel.id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final channelsNotifier = ref.read(channelsProvider.notifier);
          final rtcNotifier = ref.read(voiceRtcProvider.notifier);
          final success = isActive
              ? await channelsNotifier.leaveVoiceChannel(
                  conversationId,
                  channel.id,
                )
              : await channelsNotifier.joinVoiceChannel(
                  conversationId,
                  channel.id,
                );
          if (success && mounted) {
            if (isActive) {
              await rtcNotifier.leaveChannel();
            } else {
              await rtcNotifier.joinChannel(
                conversationId: conversationId,
                channelId: channel.id,
                startMuted:
                    voiceSettings.selfMuted || voiceSettings.selfDeafened,
              );
            }
            setState(() {
              _activeVoiceChannelId = isActive ? null : channel.id;
            });
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? context.accent.withValues(alpha: 0.18)
                  : context.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isActive
                    ? context.accent.withValues(alpha: 0.6)
                    : context.border,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.headset_mic_outlined,
                  size: 13,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  channel.name,
                  style: TextStyle(
                    color: isActive ? context.accent : context.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (participantCount > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    '($participantCount)',
                    style: TextStyle(color: context.textMuted, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineGroupChannels(
    String conversationId,
    List<GroupChannel> channels,
    ChannelsState channelsState,
    VoiceSettingsState voiceSettings,
    String? effectiveActiveVoiceChannelId,
  ) {
    final textChannels = channels.where((c) => c.isText).toList();
    final voiceChannels = channels.where((c) => c.isVoice).toList();

    if (_selectedTextChannelId == null && textChannels.isNotEmpty) {
      _selectedTextChannelId = textChannels.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadedHistoryKey = null;
        _loadHistory();
      });
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: channels.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                channelsState.isLoadingConversation(conversationId)
                    ? 'Loading channels...'
                    : 'No channels yet',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...textChannels.map(
                    (channel) => _buildTextChannelChip(channel),
                  ),
                  ...voiceChannels.map(
                    (channel) => _buildVoiceChannelChip(
                      conversationId,
                      channel,
                      channelsState.voiceSessionsFor(channel.id).length,
                      voiceSettings,
                      effectiveActiveVoiceChannelId,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildVoiceControlDock(
    String conversationId,
    List<GroupChannel> channels,
    ChannelsState channelsState,
    VoiceSettingsState voiceSettings,
    String myUserId,
    VoiceRtcState voiceRtc,
    String? effectiveActiveVoiceChannelId,
  ) {
    final activeVoiceChannel = channels
        .where((c) => c.id == effectiveActiveVoiceChannelId)
        .firstOrNull;
    if (activeVoiceChannel == null) {
      return const SizedBox.shrink();
    }

    final participants = channelsState.voiceSessionsFor(activeVoiceChannel.id);
    final iAmInChannel = participants.any((p) => p.userId == myUserId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final expectedActive =
          effectiveActiveVoiceChannelId ?? _activeVoiceChannelId;
      if (expectedActive != activeVoiceChannel.id) return;

      if (!iAmInChannel) {
        await ref.read(voiceRtcProvider.notifier).leaveChannel();
        if (mounted) {
          setState(() {
            _activeVoiceChannelId = null;
          });
        }
      }
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 16, color: context.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connected to ${activeVoiceChannel.name} • ${voiceRtc.peerConnectionStates.length} peer(s)',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (voiceRtc.isJoining)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.accent,
                ),
              ),
            ),
          IconButton(
            icon: Icon(
              voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
              size: 18,
            ),
            color: voiceSettings.selfMuted
                ? EchoTheme.danger
                : context.textSecondary,
            tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextMuted = !voiceSettings.selfMuted;
              await notifier.setSelfMuted(nextMuted);
              ref
                  .read(voiceRtcProvider.notifier)
                  .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
              await _syncVoiceState();
            },
          ),
          IconButton(
            icon: Icon(
              voiceSettings.selfDeafened
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              size: 18,
            ),
            color: voiceSettings.selfDeafened
                ? EchoTheme.danger
                : context.textSecondary,
            tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextDeafened = !voiceSettings.selfDeafened;
              await notifier.setSelfDeafened(nextDeafened);
              final lk = ref.read(voiceRtcProvider.notifier);
              lk.setCaptureEnabled(!voiceSettings.selfMuted && !nextDeafened);
              lk.setDeafened(nextDeafened);
              await _syncVoiceState();
            },
          ),
          TextButton(
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final next = !voiceSettings.pushToTalkEnabled;
              await notifier.setPushToTalkEnabled(next);
              ref
                  .read(voiceRtcProvider.notifier)
                  .setCaptureEnabled(
                    !next &&
                        !voiceSettings.selfMuted &&
                        !voiceSettings.selfDeafened,
                  );
              await _syncVoiceState();
            },
            child: Text(
              voiceSettings.pushToTalkEnabled
                  ? 'PTT ${voiceSettings.pushToTalkKeyLabel}'
                  : 'PTT Off',
            ),
          ),
          if (participants.any((p) => p.userId == myUserId))
            Icon(Icons.fiber_manual_record, size: 10, color: EchoTheme.online),
        ],
      ),
    );
  }

  void _toggleReaction(ChatMessage message, String emoji, bool alreadyReacted) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    if (alreadyReacted) {
      ref
          .read(websocketProvider.notifier)
          .removeReaction(conv.id, message.id, emoji);
      ref
          .read(chatProvider.notifier)
          .removeReaction(conv.id, message.id, myUserId, emoji);
    } else {
      ref
          .read(websocketProvider.notifier)
          .sendReaction(conv.id, message.id, emoji);
      ref
          .read(chatProvider.notifier)
          .addReaction(
            conv.id,
            Reaction(
              messageId: message.id,
              userId: myUserId,
              username: 'You',
              emoji: emoji,
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;

    if (conv == null) {
      return Container(
        color: context.chatBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 56,
                color: context.textMuted.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 20),
              Text(
                'Select a conversation to start chatting',
                style: TextStyle(color: context.textMuted, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    // Load history on first build with this conversation
    if (_loadedHistoryKey == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadHistory();
        _loadChannels();
        _markAsRead();
      });
    }

    final chatState = ref.watch(chatProvider);
    final channelsState = ref.watch(channelsProvider);
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final wsState = ref.watch(websocketProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final serverUrl = ref.watch(serverUrlProvider);
    final authToken = authState.token ?? '';

    final channels = channelsState.channelsFor(conv.id);
    final textChannels = channels.where((c) => c.isText).toList();
    final defaultTextChannelId = textChannels.isNotEmpty
        ? textChannels.first.id
        : null;
    final inferredActiveVoiceChannelId = channels
        .where((c) => c.isVoice)
        .firstWhere(
          (c) => channelsState
              .voiceSessionsFor(c.id)
              .any((m) => m.userId == myUserId),
          orElse: () => const GroupChannel(
            id: '',
            conversationId: '',
            name: '',
            kind: 'voice',
            position: 0,
            createdAt: '',
          ),
        )
        .id;
    final effectiveActiveVoiceChannelId =
        _activeVoiceChannelId ??
        (inferredActiveVoiceChannelId.isEmpty
            ? null
            : inferredActiveVoiceChannelId);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled =
        conv.isGroup &&
        selectedChannelId != null &&
        selectedChannelId == defaultTextChannelId;

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: selectedChannelId,
            includeUnchanneled: includeUnchanneled,
          )
        : chatState.messagesForConversation(conv.id);
    final isLoadingHistory = chatState.isLoadingHistory(
      conv.id,
      channelId: selectedChannelId,
    );
    final typingUsers = wsState.typingIn(conv.id, channelId: selectedChannelId);

    final displayName = conv.displayName(myUserId);
    final typingText = conv.isGroup
        ? (typingUsers.length == 1
              ? '${typingUsers.first} is typing...'
              : '${typingUsers.join(", ")} are typing...')
        : '$displayName is typing...';
    final showInputStatus = _isEditing || typingUsers.isNotEmpty;
    final inputStatusText = _isEditing && typingUsers.isNotEmpty
        ? 'Editing message • $typingText'
        : (_isEditing ? 'Editing message...' : typingText);

    // Listen for new messages to auto-scroll
    ref.listen<ChatState>(chatProvider, (prev, next) {
      int visibleCount(ChatState s) {
        if (!conv.isGroup) {
          return s.messagesForConversation(conv.id).length;
        }
        return s
            .messagesForConversationChannel(
              conv.id,
              channelId: selectedChannelId,
              includeUnchanneled: includeUnchanneled,
            )
            .length;
      }

      final prevCount = prev == null ? 0 : visibleCount(prev);
      final nextCount = visibleCount(next);
      if (nextCount > prevCount) {
        _scrollToBottom();
      }
    });

    return Container(
      color: context.chatBg,
      child: Column(
        children: [
          // Header bar -- 56px
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: context.chatBg,
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                // Avatar
                Builder(
                  builder: (_) {
                    String? headerAvatarUrl;
                    if (!conv.isGroup) {
                      final peer = conv.members
                          .where((m) => m.userId != myUserId)
                          .firstOrNull;
                      if (peer?.avatarUrl != null) {
                        headerAvatarUrl = '$serverUrl${peer!.avatarUrl}';
                      }
                    }
                    return buildAvatar(
                      name: displayName,
                      radius: 16,
                      imageUrl: headerAvatarUrl,
                      bgColor: conv.isGroup
                          ? groupAvatarColor(displayName)
                          : null,
                      fallbackIcon: conv.isGroup
                          ? const Icon(
                              Icons.group,
                              size: 14,
                              color: Colors.white,
                            )
                          : null,
                    );
                  },
                ),
                const SizedBox(width: 12),
                // Name + status
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Builder(
                        builder: (context) {
                          if (conv.isGroup) {
                            return Text(
                              '${conv.members.length} members',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 12,
                              ),
                            );
                          }
                          // For DMs, check peer presence
                          final peer = conv.members
                              .where((m) => m.userId != myUserId)
                              .firstOrNull;
                          final peerOnline =
                              peer != null && wsState.isUserOnline(peer.userId);
                          return Text(
                            peerOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                              color: peerOnline
                                  ? EchoTheme.online
                                  : context.textMuted,
                              fontSize: 12,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                // Encryption toggle for DMs
                if (!conv.isGroup)
                  IconButton(
                    icon: Icon(
                      conv.isEncrypted
                          ? Icons.lock_outlined
                          : Icons.lock_open_outlined,
                      size: 20,
                    ),
                    color: conv.isEncrypted
                        ? EchoTheme.online
                        : context.textMuted,
                    tooltip: conv.isEncrypted
                        ? 'Encryption on'
                        : 'Encryption off',
                    onPressed: () => _toggleEncryption(conv),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                // Reset encryption keys for this peer (DM + encrypted only)
                if (!conv.isGroup && conv.isEncrypted)
                  IconButton(
                    icon: const Icon(Icons.vpn_key_off, size: 18),
                    color: context.textMuted,
                    tooltip: 'Reset encryption keys',
                    onPressed: () => _resetPeerKeys(conv, myUserId),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                // Search toggle (all conversations)
                IconButton(
                  icon: Icon(
                    _showSearch ? Icons.search_off : Icons.search,
                    size: 20,
                  ),
                  color: _showSearch ? context.accent : context.textSecondary,
                  tooltip: _showSearch ? 'Close search' : 'Search messages',
                  onPressed: _toggleSearch,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                if (conv.isGroup) ...[
                  if (widget.onMembersToggle != null)
                    IconButton(
                      icon: const Icon(Icons.people_outline, size: 20),
                      color: context.textSecondary,
                      tooltip: 'Members',
                      onPressed: widget.onMembersToggle,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    color: context.textSecondary,
                    tooltip: 'Group Info',
                    onPressed: widget.onGroupInfo,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (conv.isGroup)
            _buildInlineGroupChannels(
              conv.id,
              channels,
              channelsState,
              voiceSettings,
              effectiveActiveVoiceChannelId,
            ),
          if (conv.isGroup &&
              effectiveActiveVoiceChannelId != null &&
              !widget.hideVoiceDock)
            _buildVoiceControlDock(
              conv.id,
              channels,
              channelsState,
              voiceSettings,
              myUserId,
              voiceRtc,
              effectiveActiveVoiceChannelId,
            ),
          // Search bar
          if (_showSearch)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.surface,
                border: Border(
                  bottom: BorderSide(color: context.border, width: 1),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    autofocus: true,
                    style: TextStyle(fontSize: 14, color: context.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Search messages...',
                      hintStyle: TextStyle(color: context.textMuted),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: context.textMuted,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.close,
                                size: 16,
                                color: context.textMuted,
                              ),
                              onPressed: () {
                                setState(() {
                                  _searchQuery = '';
                                  _searchResults = const [];
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: context.mainBg,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: context.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: context.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: context.accent),
                      ),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                  if (_searchResults.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _searchResults.length,
                        itemBuilder: (context, i) {
                          final r = _searchResults[i];
                          return InkWell(
                            onTap: () => _highlightMessage(r.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          r.fromUsername,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: context.textSecondary,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          r.content.length > 80
                                              ? '${r.content.substring(0, 80)}...'
                                              : r.content,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: context.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  if (_searchQuery.isNotEmpty && _searchResults.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'No results found',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          // Loading indicator for history
          if (isLoadingHistory)
            LinearProgressIndicator(
              color: context.accent,
              backgroundColor: context.chatBg,
              minHeight: 2,
            ),
          // Messages
          Expanded(
            child: messages.isEmpty && !isLoadingHistory
                ? Column(
                    children: [
                      _buildEncryptionBanner(
                        conv.isGroup,
                        isEncrypted: conv.isEncrypted,
                      ),
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              buildAvatar(
                                name: displayName,
                                radius: 36,
                                bgColor: conv.isGroup
                                    ? groupAvatarColor(displayName)
                                    : null,
                                fallbackIcon: conv.isGroup
                                    ? const Icon(
                                        Icons.group,
                                        size: 32,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                displayName,
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                conv.isGroup
                                    ? 'This is the start of #$displayName'
                                    : 'Start your conversation with $displayName',
                                style: TextStyle(
                                  color: context.textMuted,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _buildEncryptionBanner(
                          conv.isGroup,
                          isEncrypted: conv.isEncrypted,
                        );
                      }

                      final msgIndex = index - 1;
                      final msg = messages[msgIndex];

                      // Date divider
                      Widget? dateDivider;
                      if (msgIndex == 0 ||
                          _differentDay(
                            messages[msgIndex - 1].timestamp,
                            msg.timestamp,
                          )) {
                        dateDivider = _buildDateDivider(msg.timestamp);
                      }

                      if (_isSystemTimelineMessage(msg)) {
                        return Column(
                          children: [
                            ?dateDivider,
                            _buildSystemTimelineMessage(msg),
                          ],
                        );
                      }

                      // Determine grouping
                      bool showHeader = true;
                      bool isLastInGroup = true;
                      if (msgIndex > 0) {
                        final prev = messages[msgIndex - 1];
                        if (prev.fromUserId == msg.fromUserId &&
                            _withinTwoMinutes(prev.timestamp, msg.timestamp) &&
                            !_differentDay(prev.timestamp, msg.timestamp)) {
                          showHeader = false;
                        }
                      }
                      if (msgIndex < messages.length - 1) {
                        final next = messages[msgIndex + 1];
                        if (next.fromUserId == msg.fromUserId &&
                            _withinTwoMinutes(msg.timestamp, next.timestamp) &&
                            !_differentDay(msg.timestamp, next.timestamp)) {
                          isLastInGroup = false;
                        }
                      }

                      // Look up sender avatar from conversation members
                      final senderMember = conv.members
                          .where((m) => m.userId == msg.fromUserId)
                          .firstOrNull;
                      final senderAvatarUrl = senderMember?.avatarUrl;

                      final isHighlighted = _highlightedMessageId == msg.id;

                      return Column(
                        children: [
                          ?dateDivider,
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            color: isHighlighted
                                ? context.accent.withValues(alpha: 0.15)
                                : Colors.transparent,
                            child: MessageItem(
                              message: msg,
                              showHeader: showHeader,
                              isLastInGroup: isLastInGroup,
                              myUserId: myUserId,
                              serverUrl: serverUrl,
                              authToken: authToken,
                              senderAvatarUrl: senderAvatarUrl,
                              compactLayout:
                                  ref.watch(messageLayoutProvider) ==
                                  MessageLayout.compact,
                              onReactionTap: _showReactionPicker,
                              onReactionSelect: (message, emoji) {
                                final alreadyReacted = message.reactions.any(
                                  (r) =>
                                      r.emoji == emoji && r.userId == myUserId,
                                );
                                _toggleReaction(message, emoji, alreadyReacted);
                              },
                              onDelete: _confirmDelete,
                              onEdit: _enterEditMode,
                              onAvatarTap: (userId) {
                                UserProfileScreen.show(context, ref, userId);
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          // Mention autocomplete picker
          if (_showMentionPicker && _filteredMentionMembers.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              margin: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: context.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
                border: Border.all(color: context.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                reverse: true,
                padding: EdgeInsets.zero,
                itemCount: _filteredMentionMembers.length,
                itemBuilder: (context, i) {
                  final member = _filteredMentionMembers[i];
                  return InkWell(
                    onTap: () => _insertMention(member.username),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.alternate_email,
                            size: 14,
                            color: context.accent,
                          ),
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
                              style: TextStyle(
                                fontSize: 11,
                                color: context.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          // Input area
          Container(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            color: context.chatBg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showInputStatus)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
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
                          _isEditing
                              ? Icons.edit_outlined
                              : Icons.more_horiz_rounded,
                          size: 12,
                          color: _isEditing
                              ? context.accent
                              : context.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            inputStatusText,
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: _isEditing
                                  ? FontStyle.normal
                                  : FontStyle.italic,
                              color: _isEditing
                                  ? context.accent
                                  : context.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_isEditing)
                          GestureDetector(
                            onTap: _cancelEditMode,
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: context.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                Container(
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
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: PopupMenuButton<String>(
                            icon: Icon(
                              _showEmojiPicker
                                  ? Icons.keyboard_outlined
                                  : Icons.add_circle_outline,
                              size: 20,
                              color: _showEmojiPicker
                                  ? context.accent
                                  : context.textSecondary,
                            ),
                            tooltip: 'Attach or emoji',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onSelected: (value) {
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
                            },
                            itemBuilder: (context) => [
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
                              PopupMenuItem(
                                value: 'emoji',
                                child: Row(
                                  children: [
                                    Icon(
                                      _showEmojiPicker
                                          ? Icons.keyboard_outlined
                                          : Icons
                                                .sentiment_satisfied_alt_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _showEmojiPicker ? 'Keyboard' : 'Emoji',
                                    ),
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
                            ],
                          ),
                        ),
                      if (_isEditing) const SizedBox(width: 12),
                      // Text field
                      Expanded(
                        child: Focus(
                          onKeyEvent: (_, event) {
                            final pttKeyId = voiceSettings.pushToTalkKeyId;
                            final isPttKey =
                                event.logicalKey.keyId.toString() == pttKeyId;
                            final canPushToTalk =
                                voiceSettings.pushToTalkEnabled &&
                                effectiveActiveVoiceChannelId != null;

                            if (canPushToTalk && isPttKey) {
                              final allowCapture =
                                  !voiceSettings.selfMuted &&
                                  !voiceSettings.selfDeafened;
                              if (event is KeyDownEvent && allowCapture) {
                                ref
                                    .read(voiceRtcProvider.notifier)
                                    .setCaptureEnabled(true);
                                _syncVoiceState();
                              } else if (event is KeyUpEvent) {
                                ref
                                    .read(voiceRtcProvider.notifier)
                                    .setCaptureEnabled(false);
                                _syncVoiceState();
                              }
                            }

                            if (event is KeyDownEvent) {
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.escape) {
                                if (_showMentionPicker) {
                                  setState(() {
                                    _showMentionPicker = false;
                                    _mentionQuery = '';
                                  });
                                } else if (_showEmojiPicker) {
                                  setState(() => _showEmojiPicker = false);
                                } else if (_showGifPicker) {
                                  setState(() => _showGifPicker = false);
                                } else if (_isEditing) {
                                  _cancelEditMode();
                                }
                              }

                              final isPasteShortcut =
                                  event.logicalKey == LogicalKeyboardKey.keyV &&
                                  (HardwareKeyboard.instance.isControlPressed ||
                                      HardwareKeyboard.instance.isMetaPressed);
                              if (isPasteShortcut && !_isEditing) {
                                _pasteImageFromClipboard();
                              }
                            }
                            return KeyEventResult.ignored;
                          },
                          child: TextField(
                            controller: _messageController,
                            focusNode: _inputFocusNode,
                            maxLines: 5,
                            minLines: 1,
                            style: TextStyle(
                              fontSize: 14,
                              color: context.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: _isEditing
                                  ? 'Edit your message...'
                                  : 'Type a message...',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            onChanged: _onInputChanged,
                            onTap: () {
                              if (_showEmojiPicker) {
                                setState(() => _showEmojiPicker = false);
                              }
                            },
                            onSubmitted: (_) =>
                                _isEditing ? _submitEdit() : _sendMessage(),
                          ),
                        ),
                      ),
                      // Send / confirm edit button (keeps stable footprint)
                      Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: GestureDetector(
                          onTap: _isTextEmpty
                              ? null
                              : (_isEditing ? _submitEdit : _sendMessage),
                          child: Opacity(
                            opacity: _isTextEmpty ? 0.45 : 1,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: _isTextEmpty
                                    ? context.textMuted
                                    : (_isEditing
                                          ? EchoTheme.online
                                          : context.accent),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _isEditing
                                    ? Icons.check_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 18,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Emoji picker panel
          if (_showEmojiPicker)
            Container(
              height: 250,
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
                  height: 250,
                  checkPlatformCompatibility: true,
                  emojiViewConfig: EmojiViewConfig(
                    backgroundColor: context.surface,
                    columns: 8,
                    emojiSizeMax: 28,
                    noRecents: Text(
                      'No Recents',
                      style: TextStyle(fontSize: 16, color: context.textMuted),
                    ),
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: context.surface,
                    indicatorColor: context.accent,
                    iconColorSelected: context.accent,
                    iconColor: context.textMuted,
                  ),
                  bottomActionBarConfig: const BottomActionBarConfig(
                    enabled: false,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: context.surface,
                    buttonIconColor: context.textSecondary,
                    hintText: 'Search emoji...',
                  ),
                ),
              ),
            ),
          // GIF picker panel
          if (_showGifPicker)
            GifPickerWidget(
              onClose: () => setState(() => _showGifPicker = false),
              onGifSelected: (gifUrl, slug) {
                setState(() => _showGifPicker = false);
                _messageController.text = '[img:$gifUrl]';
                _sendMessage();
              },
            ),
          // Hidden RTCVideoView widgets to enable audio playback
          // Use 1x1 with zero opacity so browsers allow audio output
          ...ref
              .watch(voiceRtcProvider.notifier)
              .remoteAudioRenderers
              .values
              .map(
                (renderer) => Opacity(
                  opacity: 0,
                  child: SizedBox(
                    width: 1,
                    height: 1,
                    child: RTCVideoView(renderer),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
