import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/voice_rtc_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import 'channel_bar.dart';
import 'chat_header_bar.dart';
import 'chat_input_bar.dart';
import 'message_item.dart';
import 'message_search_overlay.dart';

/// Reaction emojis used in the picker.
const reactionEmojis = ['👍', '❤️', '😂', '😐', '😟', '🔥', '👎', '🎉'];

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
  final _scrollController = ScrollController();
  final _chatInputBarKey = GlobalKey<ChatInputBarState>();

  bool _hideEncryptionBanner = false;
  String? _selectedTextChannelId;
  String? _activeVoiceChannelId;
  String? _loadedHistoryKey;
  String? _loadedChannelsConversationId;

  bool _showSearch = false;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  double _lastKeyboardInset = 0;

  OverlayEntry? _reactionOverlay;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation?.id != oldWidget.conversation?.id) {
      _hideEncryptionBanner = false;
      _selectedTextChannelId = null;
      _activeVoiceChannelId = null;
      _loadedHistoryKey = null;
      _showSearch = false;
      _highlightedMessageId = null;
      _highlightTimer?.cancel();
      _dismissReactionPicker();
    }
  }

  @override
  void dispose() {
    _dismissReactionPicker();
    _highlightTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // History + scroll management
  // ---------------------------------------------------------------------------

  void _onScroll() {
    if (_scrollController.position.pixels <=
        _scrollController.position.minScrollExtent + 50) {
      _loadOlderMessages();
    }
  }

  void _scrollToBottom({bool animated = true, int settleRetries = 2}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      final target = _scrollController.position.maxScrollExtent;
      final alreadyAtBottom =
          (target - _scrollController.position.pixels).abs() < 1;
      if (alreadyAtBottom) return;

      Future<void> settleIfNeeded() async {
        if (settleRetries <= 0 || !_scrollController.hasClients) return;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        _scrollToBottom(animated: false, settleRetries: settleRetries - 1);
      }

      if (animated) {
        _scrollController
            .animateTo(
              target,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            )
            .whenComplete(settleIfNeeded);
      } else {
        _scrollController.jumpTo(target);
        settleIfNeeded();
      }
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  void _loadHistory() {
    final conv = widget.conversation;
    if (conv == null) return;
    final key = '${conv.id}:${_selectedTextChannelId ?? ""}';
    if (key == _loadedHistoryKey) return;
    _loadedHistoryKey = key;

    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: _selectedTextChannelId,
          isGroup: conv.isGroup,
        );
  }

  void _loadChannels() {
    final conv = widget.conversation;
    if (conv == null || !conv.isGroup) return;
    if (conv.id == _loadedChannelsConversationId) return;
    _loadedChannelsConversationId = conv.id;
    ref.read(channelsProvider.notifier).loadChannels(conv.id);
  }

  void _loadOlderMessages() {
    final conv = widget.conversation;
    if (conv == null) return;
    final chatState = ref.read(chatProvider);
    if ((chatState.loadingHistory[conv.id] ?? false) ||
        !(chatState.hasMore[conv.id] ?? true)) {
      return;
    }

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: _selectedTextChannelId,
            includeUnchanneled: _selectedTextChannelId == null,
          )
        : chatState.messagesForConversation(conv.id);
    if (messages.isEmpty) return;

    final oldestTimestamp = messages.first.timestamp;
    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: _selectedTextChannelId,
          before: oldestTimestamp,
          isGroup: conv.isGroup,
        );
  }

  void _markAsRead() {
    final conv = widget.conversation;
    if (conv == null) return;
    ref.read(conversationsProvider.notifier).markAsRead(conv.id);
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) return;
    ref.read(conversationsProvider.notifier).sendReadReceipt(conv.id);
    ref.read(websocketProvider.notifier).sendReadReceipt(conv.id);
  }

  void _onTextChannelChanged(String? channelId) {
    if (_selectedTextChannelId == channelId) return;
    setState(() {
      _selectedTextChannelId = channelId;
      _loadedHistoryKey = null;
    });
    _loadHistory();
    _markAsRead();
  }

  // ---------------------------------------------------------------------------
  // Search highlight
  // ---------------------------------------------------------------------------

  void _highlightMessage(String messageId) {
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
    _scrollToMessage(messageId);
  }

  void _scrollToMessage(String messageId) {
    final conv = widget.conversation;
    if (conv == null) return;
    final chatState = ref.read(chatProvider);
    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: _selectedTextChannelId,
            includeUnchanneled: _selectedTextChannelId == null,
          )
        : chatState.messagesForConversation(conv.id);
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0 || !_scrollController.hasClients) return;
    final estimatedOffset = (index + 1) * 60.0;
    _scrollController.animateTo(
      estimatedOffset.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ---------------------------------------------------------------------------
  // Reaction picker
  // ---------------------------------------------------------------------------

  void _dismissReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }

  void _showReactionPicker(ChatMessage message, Offset tapPosition) {
    final conv = widget.conversation;
    if (conv == null) return;
    _dismissReactionPicker();

    final myUserId = ref.read(authProvider).userId ?? '';
    final overlay = Overlay.of(context);
    const pickerWidth = 340.0;
    const pickerHeight = 44.0;
    final screenWidth = MediaQuery.of(context).size.width;

    final left = (tapPosition.dx - pickerWidth / 2).clamp(
      12.0,
      screenWidth - pickerWidth - 12,
    );
    final top = (tapPosition.dy - pickerHeight - 12).clamp(
      12.0,
      double.infinity,
    );

    _reactionOverlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                _dismissReactionPicker();
                FocusManager.instance.primaryFocus?.unfocus();
              },
              behavior: HitTestBehavior.opaque,
              child: Container(color: Colors.black.withValues(alpha: 0.15)),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (_, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - value)),
                  child: child,
                ),
              ),
              child: Container(
                height: pickerHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: context.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: context.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: reactionEmojis.map((emoji) {
                    final alreadyReacted = message.reactions.any(
                      (r) => r.emoji == emoji && r.userId == myUserId,
                    );
                    return GestureDetector(
                      onTap: () {
                        _dismissReactionPicker();
                        _toggleReaction(message, emoji, alreadyReacted);
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: alreadyReacted
                              ? context.accent.withValues(alpha: 0.2)
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          border: alreadyReacted
                              ? Border.all(color: context.accent, width: 2)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 22),
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
    overlay.insert(_reactionOverlay!);
  }

  void _toggleReaction(ChatMessage message, String emoji, bool remove) {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';
    ref
        .read(websocketProvider.notifier)
        .sendReaction(conv.id, message.id, emoji);
    if (remove) {
      ref
          .read(chatProvider.notifier)
          .removeReaction(conv.id, message.id, myUserId, emoji);
    } else {
      ref
          .read(chatProvider.notifier)
          .addReaction(
            conv.id,
            Reaction(
              messageId: message.id,
              userId: myUserId,
              username: '',
              emoji: emoji,
            ),
          );
    }
  }

  // ---------------------------------------------------------------------------
  // Delete confirmation
  // ---------------------------------------------------------------------------

  void _confirmDelete(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text('Delete Message'),
        content: const Text('This message will be removed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed != true) return;
      ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
      final serverUrl = ref.read(serverUrlProvider);
      ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/messages/${message.id}'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
    });
  }

  // ---------------------------------------------------------------------------
  // Message list helpers
  // ---------------------------------------------------------------------------

  bool _isSystemTimelineMessage(ChatMessage msg) {
    return msg.content.startsWith('[system:');
  }

  Widget _buildSystemTimelineMessage(ChatMessage msg) {
    final text = msg.content.replaceFirst('[system:', '').replaceFirst(']', '');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: context.textMuted),
              const SizedBox(width: 6),
              Text(
                text.trim(),
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
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
      final d1 = DateTime.parse(ts1);
      final d2 = DateTime.parse(ts2);
      return d1.year != d2.year || d1.month != d2.month || d1.day != d2.day;
    } catch (_) {
      return false;
    }
  }

  Widget _buildDateDivider(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      String label;
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        label = 'Today';
      } else if (dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day - 1) {
        label = 'Yesterday';
      } else {
        label = '${_monthName(dt.month)} ${dt.day}, ${dt.year}';
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Expanded(child: Divider(color: context.border, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: context.textMuted),
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

  String _monthName(int m) {
    const names = [
      '',
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
    return names[m.clamp(1, 12)];
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

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
                'Select a conversation',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Pick someone from the left to start chatting',
                style: TextStyle(color: context.textMuted, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    // Load on first build + scroll to newest message
    if (_loadedHistoryKey == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadHistory();
        _loadChannels();
        _markAsRead();
        _scrollToBottom(settleRetries: 3);
      });
    }

    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardInset != _lastKeyboardInset) {
      final wasNearBottom = _isNearBottom();
      _lastKeyboardInset = keyboardInset;
      if (wasNearBottom) {
        _scrollToBottom(animated: false, settleRetries: 2);
      }
    }

    final chatState = ref.watch(chatProvider);
    final wsState = ref.watch(websocketProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final serverUrl = ref.watch(serverUrlProvider);
    final authToken = authState.token ?? '';

    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: selectedChannelId,
            includeUnchanneled: includeUnchanneled,
          )
        : chatState.messagesForConversation(conv.id);

    final isLoadingHistory = chatState.loadingHistory[conv.id] ?? false;

    // Typing indicators
    final typingUsers = wsState
        .typingIn(conv.id, channelId: selectedChannelId)
        .where((u) => u != myUserId)
        .map((uid) {
          final member = conv.members.where((m) => m.userId == uid).firstOrNull;
          return member?.username ?? uid;
        })
        .toList();

    // Auto-scroll on new messages (only when near bottom)
    ref.listen<ChatState>(chatProvider, (prev, next) {
      int visibleCount(ChatState s) {
        if (!conv.isGroup) return s.messagesForConversation(conv.id).length;
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
      if (nextCount > prevCount && _isNearBottom()) {
        _scrollToBottom(settleRetries: 2);
      }
    });

    // Compute display name for header
    final displayName = conv.isGroup
        ? (conv.name ?? 'Group')
        : conv.members
                  .where((m) => m.userId != myUserId)
                  .firstOrNull
                  ?.username ??
              'Chat';

    // Member avatar URLs for message items
    final memberAvatars = <String, String?>{};
    for (final m in conv.members) {
      memberAvatars[m.userId] = m.avatarUrl;
    }

    return Container(
      color: context.chatBg,
      child: Column(
        children: [
          // Header
          ChatHeaderBar(
            conversation: conv,
            myUserId: myUserId,
            serverUrl: serverUrl,
            showSearch: _showSearch,
            onToggleSearch: () => setState(() => _showSearch = !_showSearch),
            onMembersToggle: widget.onMembersToggle,
            onGroupInfo: widget.onGroupInfo,
            onDismissEncryptionBanner: () =>
                setState(() => _hideEncryptionBanner = true),
            hideEncryptionBanner: _hideEncryptionBanner,
          ),

          // Channel bar (groups only)
          if (conv.isGroup)
            ChannelBar(
              conversationId: conv.id,
              selectedTextChannelId: _selectedTextChannelId,
              hideVoiceDock: widget.hideVoiceDock,
              onTextChannelChanged: _onTextChannelChanged,
              onVoiceChannelChanged: (channelId) {
                setState(() => _activeVoiceChannelId = channelId);
              },
            ),

          // Search overlay
          if (_showSearch)
            MessageSearchOverlay(
              conversationId: conv.id,
              onMessageSelected: (messageId) {
                setState(() => _showSearch = false);
                _highlightMessage(messageId);
              },
              onClose: () => setState(() => _showSearch = false),
            ),

          // Loading indicator
          if (isLoadingHistory)
            LinearProgressIndicator(
              minHeight: 2,
              color: context.accent,
              backgroundColor: context.surface,
            ),

          // Message list
          Expanded(
            child: messages.isEmpty && !isLoadingHistory
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: context.accent,
                          child: Text(
                            displayName.isNotEmpty
                                ? displayName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              fontSize: 22,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          displayName,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Start your conversation with $displayName',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return (chatState.hasMore[conv.id] ?? true)
                            ? const SizedBox(height: 40)
                            : const SizedBox(height: 8);
                      }
                      final i = index - 1;
                      final msg = messages[i];

                      if (_isSystemTimelineMessage(msg)) {
                        return _buildSystemTimelineMessage(msg);
                      }

                      // Date divider
                      final needsDateDivider =
                          i == 0 ||
                          _differentDay(
                            messages[i - 1].timestamp,
                            msg.timestamp,
                          );

                      final showHeader =
                          i == 0 ||
                          messages[i - 1].fromUserId != msg.fromUserId ||
                          !_withinTwoMinutes(
                            messages[i - 1].timestamp,
                            msg.timestamp,
                          );
                      final isLastInGroup =
                          i == messages.length - 1 ||
                          messages[i + 1].fromUserId != msg.fromUserId;

                      final senderAvatarUrl = memberAvatars[msg.fromUserId];
                      final isHighlighted = _highlightedMessageId == msg.id;

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (needsDateDivider)
                            _buildDateDivider(msg.timestamp),
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
                              onEdit: (msg) {
                                _chatInputBarKey.currentState?.enterEditMode(
                                  msg,
                                );
                              },
                              onReply: (msg) {
                                // TODO: implement reply forwarding to input bar
                              },
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

          // Input bar
          ChatInputBar(
            key: _chatInputBarKey,
            conversation: conv,
            selectedTextChannelId: _selectedTextChannelId,
            effectiveActiveVoiceChannelId: _activeVoiceChannelId,
            typingUsers: typingUsers,
            onMessageSent: () {
              _scrollToBottom(settleRetries: 2);
              _markAsRead();
            },
          ),

          // Hidden RTCVideoView widgets for voice audio playback
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
