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
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Row(
          children: [
            const Expanded(
              child: Divider(color: EchoTheme.divider, thickness: 1),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: EchoTheme.textMuted,
                ),
              ),
            ),
            const Expanded(
              child: Divider(color: EchoTheme.divider, thickness: 1),
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
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isGroup
            ? EchoTheme.warning.withValues(alpha: 0.1)
            : EchoTheme.online.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isGroup ? Icons.warning_amber_rounded : Icons.lock,
            size: 14,
            color: isGroup ? EchoTheme.warning : EchoTheme.online,
          ),
          const SizedBox(width: 6),
          Text(
            isGroup
                ? 'Group messages are not encrypted'
                : 'Messages are end-to-end encrypted',
            style: TextStyle(
              fontSize: 12,
              color: isGroup ? EchoTheme.warning : EchoTheme.online,
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
      backgroundColor: EchoTheme.panelBg,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: alreadyReacted
                        ? EchoTheme.accent.withValues(alpha: 0.3)
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
                Icons.chat_bubble_outline,
                size: 48,
                color: EchoTheme.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
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
          // Header bar
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: EchoTheme.chatBg,
              border: Border(
                bottom: BorderSide(color: EchoTheme.background, width: 1),
              ),
            ),
            child: Row(
              children: [
                if (conv.isGroup)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.tag, size: 20, color: EchoTheme.textMuted),
                  ),
                Text(
                  displayName,
                  style: const TextStyle(
                    color: EchoTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (conv.isGroup) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 20,
                    color: EchoTheme.divider,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${conv.members.length} Members',
                    style: const TextStyle(
                      color: EchoTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  color: EchoTheme.textSecondary,
                  tooltip: 'Pinned Messages',
                  onPressed: () {},
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.search, size: 18),
                  color: EchoTheme.textSecondary,
                  tooltip: 'Search',
                  onPressed: () {},
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                if (conv.isGroup)
                  IconButton(
                    icon: const Icon(Icons.people, size: 18),
                    color: EchoTheme.textSecondary,
                    tooltip: 'Members',
                    onPressed: widget.onGroupInfo,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
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
                                radius: 32,
                                backgroundColor: EchoTheme.accent,
                                child: conv.isGroup
                                    ? const Icon(Icons.tag,
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
                              const SizedBox(height: 12),
                              Text(
                                displayName,
                                style: const TextStyle(
                                  color: EchoTheme.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                conv.isGroup
                                    ? 'This is the start of #$displayName'
                                    : 'This is the beginning of your conversation with $displayName',
                                style: const TextStyle(
                                  color: EchoTheme.textMuted,
                                  fontSize: 13,
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

                      // Determine if we should show a header (avatar + name)
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
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            color: EchoTheme.chatBg,
            child: Container(
              decoration: BoxDecoration(
                color: EchoTheme.inputBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Attachment button
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 22),
                    color: EchoTheme.textSecondary,
                    tooltip: 'Attach',
                    onPressed: () {},
                  ),
                  // Text field
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: TextField(
                        controller: _messageController,
                        maxLines: null,
                        style: const TextStyle(
                          fontSize: 14,
                          color: EchoTheme.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: conv.isGroup
                              ? 'Message #$displayName'
                              : 'Message @$displayName',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onChanged: _onInputChanged,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  // Emoji button
                  IconButton(
                    icon:
                        const Icon(Icons.emoji_emotions_outlined, size: 22),
                    color: EchoTheme.textSecondary,
                    tooltip: 'Emoji',
                    onPressed: () {},
                  ),
                  // Send button (only when text is not empty)
                  if (!_isTextEmpty)
                    IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      color: EchoTheme.accent,
                      tooltip: 'Send',
                      onPressed: _sendMessage,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
