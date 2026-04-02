import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/sound_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/clipboard_image_helper.dart';
import 'conversation_panel.dart' show buildAvatar, groupAvatarColor;
import 'message_item.dart';

class ChatPanel extends ConsumerStatefulWidget {
  final Conversation? conversation;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;

  const ChatPanel({
    super.key,
    this.conversation,
    this.onMembersToggle,
    this.onGroupInfo,
  });

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();

  bool _isTextEmpty = true;
  bool _hideEncryptionBanner = false;
  String? _selectedTextChannelId;
  String? _activeVoiceChannelId;
  String? _loadedHistoryKey;
  String? _loadedChannelsConversationId;

  // Edit mode state
  ChatMessage? _editingMessage;
  bool get _isEditing => _editingMessage != null;

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Plaintext direct messages are disabled in Privacy settings',
            ),
          ),
        );
        return;
      }
    } else {
      final channels = ref.read(channelsProvider).channelsFor(conv.id);
      channelId =
          _selectedTextChannelId ??
          channels.where((c) => c.isText).firstOrNull?.id;
      if (channelId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No text channel available in this group'),
          ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to send message')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload succeeded but no URL returned')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed (${response.statusCode})')),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Uploading pasted image...'),
        duration: Duration(seconds: 1),
      ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Clipboard upload failed: $e')));
    }
  }

  Future<void> _pickFile() async {
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read file data')),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('File upload error: $e')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to toggle encryption')),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to edit message')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete message')),
        );
      }
    }
  }

  void _showReactionPicker(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: reactionEmojis.map((emoji) {
              final alreadyReacted = message.reactions.any(
                (r) => r.emoji == emoji && r.userId == myUserId,
              );
              return GestureDetector(
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleReaction(message, emoji, alreadyReacted);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: alreadyReacted
                        ? context.accent.withValues(alpha: 0.2)
                        : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
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

      final rtcNotifier = ref.read(voiceRtcProvider.notifier);
      if (!iAmInChannel) {
        await rtcNotifier.leaveChannel();
        if (mounted) {
          setState(() {
            _activeVoiceChannelId = null;
          });
        }
        return;
      }

      await rtcNotifier.syncParticipants(
        conversationId: conversationId,
        channelId: activeVoiceChannel.id,
        participantUserIds: participants.map((m) => m.userId).toList(),
      );
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
              ref
                  .read(voiceRtcProvider.notifier)
                  .setCaptureEnabled(!voiceSettings.selfMuted && !nextDeafened);
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
          if (conv.isGroup && effectiveActiveVoiceChannelId != null)
            _buildVoiceControlDock(
              conv.id,
              channels,
              channelsState,
              voiceSettings,
              myUserId,
              voiceRtc,
              effectiveActiveVoiceChannelId,
            ),
          // Hidden renderers to enable remote audio playback
          ...ref
              .watch(voiceRtcProvider.notifier)
              .remoteAudioRenderers
              .values
              .map(
                (renderer) => SizedBox(
                  width: 0,
                  height: 0,
                  child: RTCVideoView(renderer),
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

                      return Column(
                        children: [
                          ?dateDivider,
                          MessageItem(
                            message: msg,
                            showHeader: showHeader,
                            isLastInGroup: isLastInGroup,
                            myUserId: myUserId,
                            serverUrl: serverUrl,
                            authToken: authToken,
                            senderAvatarUrl: senderAvatarUrl,
                            onReactionTap: _showReactionPicker,
                            onReactionSelect: (message, emoji) {
                              final alreadyReacted = message.reactions.any(
                                (r) => r.emoji == emoji && r.userId == myUserId,
                              );
                              _toggleReaction(message, emoji, alreadyReacted);
                            },
                            onDelete: _confirmDelete,
                            onEdit: _enterEditMode,
                            onAvatarTap: (userId) {
                              UserProfileScreen.show(context, ref, userId);
                            },
                          ),
                        ],
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
                      // Attachment button (hidden in edit mode)
                      if (!_isEditing)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: IconButton(
                            icon: const Icon(
                              Icons.attach_file_outlined,
                              size: 18,
                            ),
                            color: context.textSecondary,
                            tooltip: 'Attach file',
                            onPressed: _pickFile,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
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
                                      LogicalKeyboardKey.escape &&
                                  _isEditing) {
                                _cancelEditMode();
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
                            maxLines: 1,
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
        ],
      ),
    );
  }
}
