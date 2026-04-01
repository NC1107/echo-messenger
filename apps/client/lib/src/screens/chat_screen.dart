import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';

/// Common emojis for the reaction picker.
const _reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

class ChatScreen extends ConsumerStatefulWidget {
  final String userId;
  final String username;
  final String? conversationId;
  final bool isGroup;

  const ChatScreen({
    super.key,
    required this.userId,
    required this.username,
    this.conversationId,
    this.isGroup = false,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _historyLoaded = false;
  bool _isTextEmpty = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTextEmptyChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialHistory();
      _markAsRead();
    });
  }

  @override
  void dispose() {
    _messageController.removeListener(_onTextEmptyChanged);
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onTextEmptyChanged() {
    final empty = _messageController.text.trim().isEmpty;
    if (empty != _isTextEmpty) {
      setState(() {
        _isTextEmpty = empty;
      });
    }
  }

  void _loadInitialHistory() {
    if (_historyLoaded) return;
    _historyLoaded = true;

    final convId = widget.conversationId;
    if (convId == null || convId.isEmpty) return;

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
          convId,
          auth.token!,
          auth.userId!,
          crypto: crypto,
        );
  }

  void _markAsRead() {
    final convId = widget.conversationId;
    if (convId == null || convId.isEmpty) return;

    // Immediately update local unread count to zero
    ref.read(conversationsProvider.notifier).markAsRead(convId);
    // Notify server via REST and WebSocket
    ref.read(conversationsProvider.notifier).sendReadReceipt(convId);
    ref.read(websocketProvider.notifier).sendReadReceipt(convId);
  }

  void _onScroll() {
    // Pagination: load more when scrolled to top
    if (_scrollController.position.pixels <=
        _scrollController.position.minScrollExtent + 50) {
      _loadOlderMessages();
    }
  }

  void _loadOlderMessages() {
    final convId = widget.conversationId;
    if (convId == null || convId.isEmpty) return;

    final chatState = ref.read(chatProvider);
    if (chatState.isLoadingHistory(convId)) return;
    if (!chatState.conversationHasMore(convId)) return;

    final messages = chatState.messagesForConversation(convId);
    if (messages.isEmpty) return;

    // Use the oldest message's timestamp as the "before" parameter
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
          convId,
          auth.token!,
          auth.userId!,
          before: oldestTimestamp,
          crypto: crypto,
        );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final myUserId = ref.read(authProvider).userId ?? '';
    final convId = widget.conversationId ?? '';

    ref.read(chatProvider.notifier).addOptimistic(
          widget.userId,
          text,
          myUserId,
          conversationId: convId,
        );
    _messageController.clear();
    _scrollToBottom();

    if (widget.isGroup) {
      await ref
          .read(websocketProvider.notifier)
          .sendGroupMessage(convId, text);
    } else {
      await ref
          .read(websocketProvider.notifier)
          .sendMessage(widget.userId, text, conversationId: convId);
    }
  }

  void _onTextChanged(String text) {
    final convId = widget.conversationId;
    if (convId != null && convId.isNotEmpty && text.isNotEmpty) {
      ref.read(websocketProvider.notifier).sendTyping(convId);
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

  void _showReactionPicker(ChatMessage message) {
    final convId = widget.conversationId;
    if (convId == null || convId.isEmpty) return;
    final myUserId = ref.read(authProvider).userId ?? '';

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: _reactionEmojis.map((emoji) {
              final alreadyReacted = message.reactions
                  .any((r) => r.emoji == emoji && r.userId == myUserId);
              return GestureDetector(
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (alreadyReacted) {
                    ref.read(websocketProvider.notifier).removeReaction(
                          convId,
                          message.id,
                          emoji,
                        );
                    ref.read(chatProvider.notifier).removeReaction(
                          convId,
                          message.id,
                          myUserId,
                          emoji,
                        );
                  } else {
                    ref.read(websocketProvider.notifier).sendReaction(
                          convId,
                          message.id,
                          emoji,
                        );
                    ref.read(chatProvider.notifier).addReaction(
                          convId,
                          Reaction(
                            messageId: message.id,
                            userId: myUserId,
                            username: 'You',
                            emoji: emoji,
                          ),
                        );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: alreadyReacted
                        ? Theme.of(context)
                            .colorScheme
                            .primaryContainer
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

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
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

  Widget _buildDateHeader(String timestamp) {
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
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        label = '${months[dt.month - 1]} ${dt.day}';
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _buildEncryptionBanner(bool isGroup) {
    if (isGroup) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shield_outlined, size: 14, color: Colors.orange),
            SizedBox(width: 6),
            Text(
              'Group messages are not encrypted',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outlined, size: 14, color: Colors.green[400]),
          const SizedBox(width: 6),
          Text(
            'Messages are end-to-end encrypted',
            style: TextStyle(fontSize: 12, color: Colors.green[400]),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final wsState = ref.watch(websocketProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final myUserId = ref.watch(authProvider).userId ?? '';
    final convId = widget.conversationId ?? '';

    // Use conversation-keyed messages when available, fall back to peer-keyed
    final messages = convId.isNotEmpty
        ? chatState.messagesForConversation(convId)
        : chatState.messagesFor(widget.userId);

    final isLoadingHistory =
        convId.isNotEmpty && chatState.isLoadingHistory(convId);

    // Typing indicators
    final typingUsers =
        convId.isNotEmpty ? wsState.typingIn(convId) : <String>[];

    ref.listen<ChatState>(chatProvider, (prev, next) {
      final prevCount = convId.isNotEmpty
          ? prev?.messagesForConversation(convId).length ?? 0
          : prev?.messagesFor(widget.userId).length ?? 0;
      final nextCount = convId.isNotEmpty
          ? next.messagesForConversation(convId).length
          : next.messagesFor(widget.userId).length;
      if (nextCount > prevCount) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.username),
        actions: [
          if (widget.isGroup)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Group info',
              onPressed: () {
                context.push('/group-info/$convId');
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Loading indicator for history pagination
          if (isLoadingHistory)
            const LinearProgressIndicator(),
          Expanded(
            child: messages.isEmpty && !isLoadingHistory
                ? Column(
                    children: [
                      _buildEncryptionBanner(widget.isGroup),
                      const Expanded(
                        child: Center(
                          child: Text(
                            'No messages yet. Say hello!',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    // +1 for the encryption banner at position 0
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      // First item is the encryption banner
                      if (index == 0) {
                        return _buildEncryptionBanner(widget.isGroup);
                      }

                      final msgIndex = index - 1;
                      final msg = messages[msgIndex];

                      // Show sender name in group chats
                      final showSenderName =
                          widget.isGroup && !msg.isMine;

                      // Message grouping: reduce spacing for consecutive
                      // messages from the same sender within 2 minutes
                      bool isGroupedWithPrevious = false;
                      bool isLastInGroup = true;
                      if (msgIndex > 0) {
                        final prev = messages[msgIndex - 1];
                        if (prev.fromUserId == msg.fromUserId &&
                            _withinTwoMinutes(prev.timestamp, msg.timestamp)) {
                          isGroupedWithPrevious = true;
                        }
                      }
                      if (msgIndex < messages.length - 1) {
                        final next = messages[msgIndex + 1];
                        if (next.fromUserId == msg.fromUserId &&
                            _withinTwoMinutes(msg.timestamp, next.timestamp)) {
                          isLastInGroup = false;
                        }
                      }

                      // Date headers between messages on different days
                      Widget? dateHeader;
                      if (msgIndex == 0 ||
                          _differentDay(
                              messages[msgIndex - 1].timestamp, msg.timestamp)) {
                        dateHeader = _buildDateHeader(msg.timestamp);
                      }

                      return Column(
                        children: [
                          ?dateHeader,
                          GestureDetector(
                            onLongPress: () => _showReactionPicker(msg),
                            child: _MessageBubble(
                              content: msg.content,
                              timestamp: _formatTimestamp(msg.timestamp),
                              isMine: msg.isMine,
                              colorScheme: colorScheme,
                              senderName: showSenderName
                                  ? msg.fromUsername
                                  : null,
                              status: msg.isMine ? msg.status : null,
                              reactions: msg.reactions,
                              myUserId: myUserId,
                              isGroupedWithPrevious: isGroupedWithPrevious,
                              showTimestamp: isLastInGroup,
                            ),
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
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: Text(
                widget.isGroup
                    ? (typingUsers.length == 1
                        ? '${typingUsers.first} is typing...'
                        : '${typingUsers.join(", ")} are typing...')
                    : 'typing...',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onChanged: _onTextChanged,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isTextEmpty ? null : _sendMessage,
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final String timestamp;
  final bool isMine;
  final ColorScheme colorScheme;
  final String? senderName;
  final MessageStatus? status;
  final List<Reaction> reactions;
  final String myUserId;
  final bool isGroupedWithPrevious;
  final bool showTimestamp;

  const _MessageBubble({
    required this.content,
    required this.timestamp,
    required this.isMine,
    required this.colorScheme,
    this.senderName,
    this.status,
    this.reactions = const [],
    this.myUserId = '',
    this.isGroupedWithPrevious = false,
    this.showTimestamp = true,
  });

  Widget _buildStatusIcon() {
    if (!isMine || status == null) return const SizedBox.shrink();

    switch (status!) {
      case MessageStatus.sending:
        return Icon(
          Icons.schedule_outlined,
          size: 14,
          color: colorScheme.onPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.sent:
        return Icon(
          Icons.check_outlined,
          size: 14,
          color: colorScheme.onPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all_outlined,
          size: 14,
          color: colorScheme.onPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: colorScheme.error,
        );
    }
  }

  Widget _buildReactions() {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Group reactions by emoji
    final grouped = <String, List<Reaction>>{};
    for (final r in reactions) {
      grouped.putIfAbsent(r.emoji, () => []).add(r);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        children: grouped.entries.map((entry) {
          final hasMyReaction =
              entry.value.any((r) => r.userId == myUserId);
          return Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hasMyReaction
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: hasMyReaction
                  ? Border.all(color: colorScheme.primary, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(entry.key, style: const TextStyle(fontSize: 12)),
                if (entry.value.length > 1) ...[
                  const SizedBox(width: 2),
                  Text(
                    '${entry.value.length}',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFailed = status == MessageStatus.failed;
    final bubbleColor = isFailed
        ? colorScheme.errorContainer
        : isMine
            ? colorScheme.primary
            : const Color(0xFF2A2D3E);
    final textColor = isFailed
        ? colorScheme.onErrorContainer
        : isMine
            ? colorScheme.onPrimary
            : colorScheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            margin: EdgeInsets.symmetric(
              vertical: isGroupedWithPrevious ? 1 : 4,
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMine ? 16 : 4),
                bottomRight: Radius.circular(isMine ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (senderName != null && !isGroupedWithPrevious)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      senderName!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.tertiary,
                      ),
                    ),
                  ),
                Text(
                  content,
                  style: TextStyle(color: textColor),
                ),
                if (showTimestamp) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        timestamp,
                        style: TextStyle(
                          fontSize: 11,
                          color: isMine
                              ? colorScheme.onPrimary
                                  .withValues(alpha: 0.7)
                              : colorScheme.onSurface
                                  .withValues(alpha: 0.5),
                        ),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 4),
                        _buildStatusIcon(),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          _buildReactions(),
        ],
      ),
    );
  }
}
