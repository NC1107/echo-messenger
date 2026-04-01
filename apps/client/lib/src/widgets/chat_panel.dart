import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/sound_service.dart';
import '../theme/echo_theme.dart';
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
  String? _loadedConversationId;

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
      _loadHistory();
      _markAsRead();
    }
  }

  @override
  void dispose() {
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
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
    if (conv.id == _loadedConversationId) return;

    _loadedConversationId = conv.id;

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
          crypto: crypto,
          isGroup: conv.isGroup,
        );
  }

  void _markAsRead() {
    final conv = widget.conversation;
    if (conv == null) return;

    ref.read(conversationsProvider.notifier).markAsRead(conv.id);
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

    final chatState = ref.read(chatProvider);
    if (chatState.isLoadingHistory(conv.id)) return;
    if (!chatState.conversationHasMore(conv.id)) return;

    final messages = chatState.messagesForConversation(conv.id);
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
          before: oldestTimestamp,
          crypto: crypto,
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
    if (!conv.isGroup) {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      peerUserId = peer?.userId ?? '';
    }

    ref
        .read(chatProvider.notifier)
        .addOptimistic(peerUserId, text, myUserId, conversationId: conv.id);
    _messageController.clear();
    _scrollToBottom();
    SoundService().playMessageSent();

    try {
      if (conv.isGroup) {
        await ref
            .read(websocketProvider.notifier)
            .sendGroupMessage(conv.id, text);
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
      ref.read(websocketProvider.notifier).sendTyping(conv.id);
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

      // Upload to server
      final serverUrl = ref.read(serverUrlProvider);
      final token = ref.read(authProvider).token;
      if (token == null) return;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/api/media/upload'),
      );
      request.headers['Authorization'] = 'Bearer $token';
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

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
          contentType: MediaType(mime[0], mime[1]),
        ),
      );

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(body);
        final mediaUrl = data['url'] as String?;
        if (mediaUrl != null) {
          // Send as message with image marker
          _messageController.text = '[img:$mediaUrl]';
          _sendMessage();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Upload succeeded but no URL returned'),
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed (${response.statusCode})')),
        );
      }
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

  Widget _buildEncryptionBanner(bool isGroup) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isGroup
            ? context.surface
            : EchoTheme.online.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isGroup ? Icons.shield_outlined : Icons.lock_outlined,
            size: 14,
            color: isGroup ? context.textMuted : EchoTheme.online,
          ),
          const SizedBox(width: 8),
          Text(
            isGroup
                ? 'Group messages are not encrypted'
                : 'Messages are end-to-end encrypted',
            style: TextStyle(
              fontSize: isGroup ? 11 : 12,
              color: isGroup ? context.textMuted : EchoTheme.online,
            ),
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
    if (_loadedConversationId != conv.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadHistory();
        _markAsRead();
      });
    }

    final chatState = ref.watch(chatProvider);
    final wsState = ref.watch(websocketProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final serverUrl = ref.watch(serverUrlProvider);
    final authToken = authState.token ?? '';

    final messages = chatState.messagesForConversation(conv.id);
    final isLoadingHistory = chatState.isLoadingHistory(conv.id);
    final typingUsers = wsState.typingIn(conv.id);

    final displayName = conv.displayName(myUserId);

    // Listen for new messages to auto-scroll
    ref.listen<ChatState>(chatProvider, (prev, next) {
      final prevCount = prev?.messagesForConversation(conv.id).length ?? 0;
      final nextCount = next.messagesForConversation(conv.id).length;
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
                      _buildEncryptionBanner(conv.isGroup),
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
                        return _buildEncryptionBanner(conv.isGroup);
                      }

                      final msgIndex = index - 1;
                      final msg = messages[msgIndex];

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

                      // Date divider
                      Widget? dateDivider;
                      if (msgIndex == 0 ||
                          _differentDay(
                            messages[msgIndex - 1].timestamp,
                            msg.timestamp,
                          )) {
                        dateDivider = _buildDateDivider(msg.timestamp);
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
          // Typing indicator
          if (typingUsers.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                conv.isGroup
                    ? (typingUsers.length == 1
                          ? '${typingUsers.first} is typing...'
                          : '${typingUsers.join(", ")} are typing...')
                    : '$displayName is typing...',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: context.textMuted,
                ),
              ),
            ),
          // Edit mode banner
          if (_isEditing)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              color: context.accent.withValues(alpha: 0.08),
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 14, color: context.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Editing message...',
                      style: TextStyle(
                        color: context.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _cancelEditMode,
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: context.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          // Input area
          Container(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            color: context.chatBg,
            child: Container(
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
                        icon: const Icon(Icons.attach_file_outlined, size: 18),
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
                    child: KeyboardListener(
                      focusNode: FocusNode(),
                      onKeyEvent: (event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape &&
                            _isEditing) {
                          _cancelEditMode();
                        }
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
                  // Send / confirm edit button
                  if (!_isTextEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: GestureDetector(
                        onTap: _isEditing ? _submitEdit : _sendMessage,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: _isEditing
                                ? EchoTheme.online
                                : context.accent,
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
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
