import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/threads_inbox_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import '../theme/responsive.dart';
import 'message/media_content.dart';
import 'message/reply_quote.dart';
import 'message/rich_text_content.dart';

const _kReplyHintText = 'Reply in thread...';

/// Shows all replies to a given parent message in a side panel or bottom sheet.
///
/// The parent message is displayed at the top with full media rendering,
/// followed by a chronological list of replies — also with media — and a
/// dedicated text input at the bottom so the user can send replies without
/// leaving the panel.
///
/// Replies are sourced reactively from [chatProvider] so that messages
/// arriving via WebSocket while the panel is open appear immediately without
/// a manual refresh.  The initial HTTP fetch seeds the provider with
/// historical replies that may not yet be in memory.
class ThreadViewPanel extends ConsumerStatefulWidget {
  final ChatMessage parentMessage;
  final String? serverUrl;
  final String? authToken;

  /// Optional channel scope so thread replies in a multi-channel group go
  /// to the same text channel as the parent message.
  final String? selectedTextChannelId;

  /// Legacy hook used by the desktop layout to route through the main chat
  /// input. The panel now sends inline by default; if [onReply] is provided
  /// it is invoked alongside the inline send for backward compatibility
  /// (e.g. to focus / scroll the host panel).
  final void Function(ChatMessage message)? onReply;

  final VoidCallback onClose;

  const ThreadViewPanel({
    super.key,
    required this.parentMessage,
    this.serverUrl,
    this.authToken,
    this.selectedTextChannelId,
    this.onReply,
    required this.onClose,
  });

  @override
  ConsumerState<ThreadViewPanel> createState() => _ThreadViewPanelState();
}

class _ThreadViewPanelState extends ConsumerState<ThreadViewPanel> {
  bool _isLoading = true;
  String? _error;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadReplies();
    // Threads M3: opening the panel implicitly marks this thread as
    // read. Fire-and-forget on the inbox provider — fails silently if
    // offline; the next inbox refresh re-derives the truth.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(threadsInboxProvider.notifier).markRead(widget.parentMessage.id);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final serverUrl = ref.read(serverUrlProvider);
    final messageId = widget.parentMessage.id;

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/messages/$messageId/replies?limit=100'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _processFetchedReplies(response.body);
      } else {
        _setError('Failed to load replies');
      }
    } catch (e) {
      _setError('Failed to load replies');
    }
  }

  Future<void> _processFetchedReplies(String responseBody) async {
    final List<dynamic> data = jsonDecode(responseBody) as List<dynamic>;
    final myUserId = ref.read(authProvider).userId ?? '';
    final notifier = ref.read(chatProvider.notifier);
    final chatState = ref.read(chatProvider);
    final existingIds = chatState
        .messagesForConversation(widget.parentMessage.conversationId)
        .map((m) => m.id)
        .toSet();

    for (final json in data) {
      final reply = ChatMessage.fromServerJson(
        json as Map<String, dynamic>,
        myUserId,
      );
      if (!existingIds.contains(reply.id)) {
        notifier.addMessage(reply, bumpReplyCount: false);
      }
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: MotionDurations.expressive,
      curve: MotionCurves.entrance,
    );
  }

  Conversation? _findConversation() {
    final convs = ref.read(conversationsProvider).conversations;
    return convs
        .where((c) => c.id == widget.parentMessage.conversationId)
        .firstOrNull;
  }

  Future<void> _sendThreadReply(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final conv = _findConversation();
    if (conv == null) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Conversation unavailable',
        type: ToastType.error,
      );
      return;
    }
    final myUserId = ref.read(authProvider).userId ?? '';
    final parent = widget.parentMessage;
    final threadRootId = parent.threadRootId ?? parent.id;

    String peerUserId = '';
    if (!conv.isGroup) {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      peerUserId = peer?.userId ?? '';
    }

    ref
        .read(chatProvider.notifier)
        .addOptimistic(
          peerUserId,
          trimmed,
          myUserId,
          conversationId: conv.id,
          channelId: widget.selectedTextChannelId,
          replyToId: parent.id,
          replyToContent: parent.content,
          replyToUsername: parent.fromUsername,
          threadRootId: threadRootId,
        );

    try {
      if (conv.isGroup) {
        await ref
            .read(websocketProvider.notifier)
            .sendGroupMessage(
              conv.id,
              trimmed,
              channelId: widget.selectedTextChannelId,
              replyToId: parent.id,
              threadRootId: threadRootId,
            );
      } else {
        await ref
            .read(websocketProvider.notifier)
            .sendMessage(
              peerUserId,
              trimmed,
              conversationId: conv.id,
              replyToId: parent.id,
              threadRootId: threadRootId,
            );
      }
    } catch (_) {
      if (!mounted) return;
      ToastService.show(context, 'Failed to send reply', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final parent = widget.parentMessage;

    final allMessages = ref.watch(
      chatProvider.select(
        (s) => s.messagesForConversation(parent.conversationId),
      ),
    );
    final replies = allMessages
        .where((m) => m.threadRootId == parent.id || m.replyToId == parent.id)
        .toList();

    // Scroll to bottom when a new reply arrives while the panel is open.
    // Use ref.listen to trigger the side-effect outside the build phase.
    ref.listen<List<ChatMessage>>(
      chatProvider.select(
        (s) => s
            .messagesForConversation(parent.conversationId)
            .where(
              (m) => m.threadRootId == parent.id || m.replyToId == parent.id,
            )
            .toList(),
      ),
      (prev, next) {
        if (!_isLoading && next.length > (prev?.length ?? 0)) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
        }
      },
    );

    return Container(
      width: isMobile ? double.infinity : 380,
      decoration: BoxDecoration(
        color: context.surface,
        border: isMobile
            ? null
            : Border(left: BorderSide(color: context.border)),
      ),
      child: Column(
        children: [
          _ThreadHeader(
            parentMessage: parent,
            replyCount: replies.length,
            onClose: widget.onClose,
          ),
          _ThreadParentMessage(
            parent: parent,
            replyCount: replies.length,
            isLoading: _isLoading,
            serverUrl: widget.serverUrl,
            authToken: widget.authToken,
          ),
          Divider(height: 1, color: context.border),
          Expanded(
            child: _ThreadReplyList(
              replies: replies,
              parentMessageId: parent.id,
              isLoading: _isLoading,
              error: _error,
              onRetry: _loadReplies,
              scrollController: _scrollController,
              serverUrl: widget.serverUrl,
              authToken: widget.authToken,
            ),
          ),
          _ThreadReplyInput(onSend: _sendThreadReply),
        ],
      ),
    );
  }
}

/// Header row with thread title + reply count, optional face-stack of recent
/// repliers, and a close button.
class _ThreadHeader extends StatelessWidget {
  final ChatMessage parentMessage;
  final int replyCount;
  final VoidCallback onClose;

  const _ThreadHeader({
    required this.parentMessage,
    required this.replyCount,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, size: 18, color: context.accent),
          const SizedBox(width: 10),
          Expanded(child: _buildTitle(context)),
          if (parentMessage.recentReplierUsernames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _ReplierFaceStack(
                usernames: parentMessage.recentReplierUsernames,
              ),
            ),
          Semantics(
            label: 'Close thread',
            button: true,
            child: IconButton(
              icon: Icon(Icons.close, size: 18, color: context.textMuted),
              tooltip: 'Close thread',
              onPressed: onClose,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Thread',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: context.textPrimary,
            height: 1.1,
          ),
        ),
        if (replyCount > 0) ...[
          const SizedBox(height: 2),
          Text(
            '$replyCount '
            '${replyCount == 1 ? "reply" : "replies"} · '
            'started by ${parentMessage.fromUsername}',
            style: TextStyle(fontSize: 11, color: context.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Parent message card pinned to the top of the thread panel. Renders media
/// inline (image / video / audio / file) — previously this leaked `[audio:URL]`
/// raw tokens as plain text (#11a).
class _ThreadParentMessage extends StatelessWidget {
  final ChatMessage parent;
  final int replyCount;
  final bool isLoading;
  final String? serverUrl;
  final String? authToken;

  const _ThreadParentMessage({
    required this.parent,
    required this.replyCount,
    required this.isLoading,
    required this.serverUrl,
    required this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: context.chatBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                parent.fromUsername,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTimestamp(parent.timestamp),
                style: TextStyle(fontSize: 11, color: context.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _ThreadMessageBody(
            content: parent.content,
            isMine: parent.isMine,
            serverUrl: serverUrl,
            authToken: authToken,
            compact: false,
          ),
          if (replyCount > 0 && !isLoading) ...[
            const SizedBox(height: 8),
            Text(
              '$replyCount ${replyCount == 1 ? 'reply' : 'replies'}',
              style: TextStyle(
                fontSize: 12,
                color: context.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Reply list: handles loading, error, empty, and populated states.
class _ThreadReplyList extends StatelessWidget {
  final List<ChatMessage> replies;
  final String parentMessageId;
  final bool isLoading;
  final String? error;
  final VoidCallback onRetry;
  final ScrollController scrollController;
  final String? serverUrl;
  final String? authToken;

  const _ThreadReplyList({
    required this.replies,
    required this.parentMessageId,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.scrollController,
    required this.serverUrl,
    required this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) return _buildLoading();
    if (error != null) return _buildError(context);
    if (replies.isEmpty) return _buildEmpty(context);
    return _buildList(context);
  }

  Widget _buildLoading() {
    return const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 32, color: context.textMuted),
          const SizedBox(height: 8),
          Text(
            error!,
            style: TextStyle(fontSize: 13, color: context.textMuted),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 32,
            color: context.textMuted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text(
            'No replies yet',
            style: TextStyle(fontSize: 13, color: context.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            'Be the first to reply',
            style: TextStyle(fontSize: 12, color: context.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: replies.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final reply = replies[index];
        return _ThreadReplyItem(
          reply: reply,
          parentMessageId: parentMessageId,
          serverUrl: serverUrl,
          authToken: authToken,
        );
      },
    );
  }
}

/// Single reply row inside the thread list. Renders media (audio / image /
/// video / file) inline rather than as raw `[audio:URL]` tokens (#11a).
class _ThreadReplyItem extends StatelessWidget {
  final ChatMessage reply;
  final String parentMessageId;
  final String? serverUrl;
  final String? authToken;

  const _ThreadReplyItem({
    required this.reply,
    required this.parentMessageId,
    required this.serverUrl,
    required this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    final isMine = reply.isMine;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                reply.fromUsername,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isMine ? context.accent : context.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTimestamp(reply.timestamp),
                style: TextStyle(fontSize: 10, color: context.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (reply.replyToContent != null &&
              reply.replyToId != parentMessageId)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ReplyQuote(
                replyToUsername: reply.replyToUsername,
                replyToContent: reply.replyToContent!,
                isMine: isMine,
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isMine ? context.sentBubble : context.recvBubble,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _ThreadMessageBody(
              content: reply.content,
              isMine: isMine,
              serverUrl: serverUrl,
              authToken: authToken,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders message content for the thread surface: inline media + optional
/// caption, falling back to [RichTextContent] when there is no media marker.
class _ThreadMessageBody extends StatelessWidget {
  final String content;
  final bool isMine;
  final String? serverUrl;
  final String? authToken;
  final bool compact;

  const _ThreadMessageBody({
    required this.content,
    required this.isMine,
    required this.serverUrl,
    required this.authToken,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final mediaUrl = extractMediaUrl(content);
    if (mediaUrl == null) {
      return RichTextContent(
        text: content,
        textColor: context.textPrimary,
        accentHoverColor: context.accentHover,
        textSecondaryColor: context.textSecondary,
        compact: compact,
      );
    }
    final caption = extractMediaCaption(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MediaContent(
          content: content,
          isMine: isMine,
          serverUrl: serverUrl,
          authToken: authToken,
        ),
        if (caption != null && caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          RichTextContent(
            text: caption,
            textColor: context.textPrimary,
            accentHoverColor: context.accentHover,
            textSecondaryColor: context.textSecondary,
            compact: compact,
          ),
        ],
      ],
    );
  }
}

/// Dedicated text input pinned to the bottom of the thread panel. Sends
/// replies inline within the thread (#11b) — no longer routes through the
/// main chat input bar.
class _ThreadReplyInput extends StatefulWidget {
  final Future<void> Function(String text) onSend;

  const _ThreadReplyInput({required this.onSend});

  @override
  State<_ThreadReplyInput> createState() => _ThreadReplyInputState();
}

class _ThreadReplyInputState extends State<_ThreadReplyInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final has = _controller.text.trim().isNotEmpty;
    if (has != _hasText) {
      setState(() => _hasText = has);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      if (mounted) {
        _controller.clear();
        _focusNode.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _buildTextField(context)),
            const SizedBox(width: 8),
            _buildSendButton(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.chatBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: !_sending,
        minLines: 1,
        maxLines: 5,
        textInputAction: TextInputAction.newline,
        onSubmitted: (_) => _handleSend(),
        style: TextStyle(fontSize: 14, color: context.textPrimary),
        decoration: InputDecoration(
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: InputBorder.none,
          hintText: _kReplyHintText,
          hintStyle: TextStyle(fontSize: 13, color: context.textMuted),
        ),
      ),
    );
  }

  Widget _buildSendButton(BuildContext context) {
    final enabled = _hasText && !_sending;
    final bg = enabled
        ? context.accent
        : context.textMuted.withValues(alpha: 0.25);
    return Semantics(
      label: 'Send thread reply',
      button: true,
      enabled: enabled,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? _handleSend : null,
            child: Center(
              child: Icon(
                Icons.arrow_upward,
                color: context.onAccent,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatTimestamp(String timestamp) {
  try {
    final dt = DateTime.parse(timestamp).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  } catch (_) {
    return '';
  }
}

/// Shows the thread view as a bottom sheet on mobile.
void showThreadBottomSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ChatMessage parentMessage,
  String? serverUrl,
  String? authToken,
  String? selectedTextChannelId,
  void Function(ChatMessage message)? onReply,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollController) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: ThreadViewPanel(
          parentMessage: parentMessage,
          serverUrl: serverUrl,
          authToken: authToken,
          selectedTextChannelId: selectedTextChannelId,
          onReply: onReply,
          onClose: () => Navigator.pop(sheetContext),
        ),
      ),
    ),
  );
}

/// Up to 3 overlapping initial-circles for recent repliers, rendered in
/// the thread header so the user can see at a glance who's been
/// chatting. Smaller cousin of the reply-chip face stack.
class _ReplierFaceStack extends StatelessWidget {
  const _ReplierFaceStack({required this.usernames});
  final List<String> usernames;

  @override
  Widget build(BuildContext context) {
    final faces = usernames.take(3).toList();
    const faceSize = 18.0;
    const overlap = 6.0;
    final width = faceSize + (faces.length - 1) * (faceSize - overlap);
    return SizedBox(
      width: width,
      height: faceSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < faces.length; i++)
            Positioned(
              left: i * (faceSize - overlap),
              child: _SmallInitialCircle(name: faces[i], size: faceSize),
            ),
        ],
      ),
    );
  }
}

class _SmallInitialCircle extends StatelessWidget {
  const _SmallInitialCircle({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final hue = (name.hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1.0, hue, 0.55, 0.45).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: context.surface, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: context.onAccent,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
