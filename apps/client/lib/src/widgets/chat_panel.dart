import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
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
  bool _isTextEmpty = true;
  String? _loadedConversationId;

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

    ref.read(chatProvider.notifier).loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          crypto: crypto,
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

    ref.read(chatProvider.notifier).loadHistoryWithUserId(
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
      final peer = conv.members
          .where((m) => m.userId != myUserId)
          .firstOrNull;
      peerUserId = peer?.userId ?? '';
    }

    ref.read(chatProvider.notifier).addOptimistic(
          peerUserId,
          text,
          myUserId,
          conversationId: conv.id,
        );
    _messageController.clear();
    _scrollToBottom();

    if (conv.isGroup) {
      await ref
          .read(websocketProvider.notifier)
          .sendGroupMessage(conv.id, text);
    } else {
      await ref.read(websocketProvider.notifier).sendMessage(
            peerUserId,
            text,
            conversationId: conv.id,
          );
    }
  }

  void _onInputChanged(String text) {
    final conv = widget.conversation;
    if (conv != null && text.isNotEmpty) {
      ref.read(websocketProvider.notifier).sendTyping(conv.id);
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
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        label = '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
        child: Row(
          children: [
            const Expanded(
              child: Divider(color: EchoTheme.border, thickness: 1),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: EchoTheme.textMuted,
                ),
              ),
            ),
            const Expanded(
              child: Divider(color: EchoTheme.border, thickness: 1),
            ),
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
            ? EchoTheme.surface
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
            color: isGroup ? EchoTheme.textMuted : EchoTheme.online,
          ),
          const SizedBox(width: 8),
          Text(
            isGroup
                ? 'Group messages are not encrypted'
                : 'Messages are end-to-end encrypted',
            style: TextStyle(
              fontSize: isGroup ? 11 : 12,
              color: isGroup ? EchoTheme.textMuted : EchoTheme.online,
            ),
          ),
        ],
      ),
    );
  }

  void _showReactionPicker(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: EchoTheme.surface,
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
              final alreadyReacted = message.reactions
                  .any((r) => r.emoji == emoji && r.userId == myUserId);
              return GestureDetector(
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleReaction(message, emoji, alreadyReacted);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: alreadyReacted
                        ? EchoTheme.accent.withValues(alpha: 0.2)
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

  void _toggleReaction(
      ChatMessage message, String emoji, bool alreadyReacted) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    if (alreadyReacted) {
      ref.read(websocketProvider.notifier).removeReaction(
            conv.id,
            message.id,
            emoji,
          );
      ref.read(chatProvider.notifier).removeReaction(
            conv.id,
            message.id,
            myUserId,
            emoji,
          );
    } else {
      ref.read(websocketProvider.notifier).sendReaction(
            conv.id,
            message.id,
            emoji,
          );
      ref.read(chatProvider.notifier).addReaction(
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
        color: EchoTheme.chatBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 56,
                color: EchoTheme.textMuted.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 20),
              const Text(
                'Select a conversation to start chatting',
                style: TextStyle(
                  color: EchoTheme.textMuted,
                  fontSize: 16,
                ),
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
    final myUserId = ref.watch(authProvider).userId ?? '';

    final messages = chatState.messagesForConversation(conv.id);
    final isLoadingHistory = chatState.isLoadingHistory(conv.id);
    final typingUsers = wsState.typingIn(conv.id);

    final displayName = conv.displayName(myUserId);

    // Listen for new messages to auto-scroll
    ref.listen<ChatState>(chatProvider, (prev, next) {
      final prevCount =
          prev?.messagesForConversation(conv.id).length ?? 0;
      final nextCount = next.messagesForConversation(conv.id).length;
      if (nextCount > prevCount) {
        _scrollToBottom();
      }
    });

    return Container(
      color: EchoTheme.chatBg,
      child: Column(
        children: [
          // Header bar -- 56px
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              color: EchoTheme.chatBg,
              border: Border(
                bottom: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                // Avatar
                CircleAvatar(
                  radius: 16,
                  backgroundColor: conv.isGroup
                      ? EchoTheme.accent
                      : _avatarColor(displayName),
                  child: conv.isGroup
                      ? const Icon(Icons.group, size: 14, color: Colors.white)
                      : Text(
                          displayName.isNotEmpty
                              ? displayName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
                        style: const TextStyle(
                          color: EchoTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        conv.isGroup
                            ? '${conv.members.length} members'
                            : 'Online',
                        style: const TextStyle(
                          color: EchoTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search_outlined, size: 20),
                  color: EchoTheme.textSecondary,
                  tooltip: 'Search',
                  onPressed: () {},
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                if (conv.isGroup)
                  IconButton(
                    icon: const Icon(Icons.people_outline, size: 20),
                    color: EchoTheme.textSecondary,
                    tooltip: 'Members',
                    onPressed: widget.onGroupInfo,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
              ],
            ),
          ),
          // Loading indicator for history
          if (isLoadingHistory)
            const LinearProgressIndicator(
              color: EchoTheme.accent,
              backgroundColor: EchoTheme.chatBg,
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
                              CircleAvatar(
                                radius: 36,
                                backgroundColor: conv.isGroup
                                    ? EchoTheme.accent
                                    : _avatarColor(displayName),
                                child: conv.isGroup
                                    ? const Icon(Icons.group,
                                        size: 32, color: Colors.white)
                                    : Text(
                                        displayName.isNotEmpty
                                            ? displayName[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                displayName,
                                style: const TextStyle(
                                  color: EchoTheme.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                conv.isGroup
                                    ? 'This is the start of #$displayName'
                                    : 'Start your conversation with $displayName',
                                style: const TextStyle(
                                  color: EchoTheme.textMuted,
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
                            _withinTwoMinutes(
                                prev.timestamp, msg.timestamp) &&
                            !_differentDay(
                                prev.timestamp, msg.timestamp)) {
                          showHeader = false;
                        }
                      }
                      if (msgIndex < messages.length - 1) {
                        final next = messages[msgIndex + 1];
                        if (next.fromUserId == msg.fromUserId &&
                            _withinTwoMinutes(
                                msg.timestamp, next.timestamp) &&
                            !_differentDay(
                                msg.timestamp, next.timestamp)) {
                          isLastInGroup = false;
                        }
                      }

                      // Date divider
                      Widget? dateDivider;
                      if (msgIndex == 0 ||
                          _differentDay(messages[msgIndex - 1].timestamp,
                              msg.timestamp)) {
                        dateDivider = _buildDateDivider(msg.timestamp);
                      }

                      return Column(
                        children: [
                          ?dateDivider,
                          MessageItem(
                            message: msg,
                            showHeader: showHeader,
                            isLastInGroup: isLastInGroup,
                            myUserId: myUserId,
                            onReactionTap: _showReactionPicker,
                            onReactionSelect: (message, emoji) {
                              final alreadyReacted = message.reactions
                                  .any((r) =>
                                      r.emoji == emoji &&
                                      r.userId == myUserId);
                              _toggleReaction(
                                  message, emoji, alreadyReacted);
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                conv.isGroup
                    ? (typingUsers.length == 1
                        ? '${typingUsers.first} is typing...'
                        : '${typingUsers.join(", ")} are typing...')
                    : '$displayName is typing...',
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: EchoTheme.textMuted,
                ),
              ),
            ),
          // Input area
          Container(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            color: EchoTheme.chatBg,
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: EchoTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: EchoTheme.border, width: 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Attachment button
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: IconButton(
                      icon: const Icon(Icons.attach_file_outlined, size: 18),
                      color: EchoTheme.textSecondary,
                      tooltip: 'Attach',
                      onPressed: () {},
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ),
                  // Text field
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 14,
                        color: EchoTheme.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 10),
                      ),
                      onChanged: _onInputChanged,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  // Emoji button
                  IconButton(
                    icon:
                        const Icon(Icons.sentiment_satisfied_alt_outlined, size: 18),
                    color: EchoTheme.textSecondary,
                    tooltip: 'Emoji',
                    onPressed: () {},
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  // Send button
                  if (!_isTextEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: GestureDetector(
                        onTap: _sendMessage,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: const BoxDecoration(
                            color: EchoTheme.accent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.arrow_upward_rounded,
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

  Color _avatarColor(String name) {
    final colors = [
      const Color(0xFFE06666),
      const Color(0xFFF6B05C),
      const Color(0xFF57D28F),
      const Color(0xFF5DADE2),
      const Color(0xFFAF7AC5),
      const Color(0xFFEB984E),
    ];
    final index = name.hashCode.abs() % colors.length;
    return colors[index];
  }
}
