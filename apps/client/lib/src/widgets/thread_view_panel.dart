import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import 'message/reply_quote.dart';

/// Shows all replies to a given parent message in a side panel or bottom sheet.
///
/// The parent message is displayed at the top, followed by a chronological list
/// of replies. Users can compose new replies from this panel.
class ThreadViewPanel extends ConsumerStatefulWidget {
  final ChatMessage parentMessage;
  final String? serverUrl;
  final String? authToken;
  final void Function(ChatMessage message)? onReply;
  final VoidCallback onClose;

  const ThreadViewPanel({
    super.key,
    required this.parentMessage,
    this.serverUrl,
    this.authToken,
    this.onReply,
    required this.onClose,
  });

  @override
  ConsumerState<ThreadViewPanel> createState() => _ThreadViewPanelState();
}

class _ThreadViewPanelState extends ConsumerState<ThreadViewPanel> {
  List<ChatMessage> _replies = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReplies();
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
        final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
        final myUserId = ref.read(authProvider).userId ?? '';
        final replies = data
            .map(
              (json) => ChatMessage.fromServerJson(
                json as Map<String, dynamic>,
                myUserId,
              ),
            )
            .toList();
        setState(() {
          _replies = replies;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load replies';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load replies';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final parent = widget.parentMessage;

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
          _buildHeader(context),
          Divider(height: 1, color: context.border),
          _buildParentMessage(context, parent),
          Divider(height: 1, color: context.border),
          Expanded(child: _buildRepliesList(context)),
          _buildReplyAction(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, size: 18, color: context.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Thread',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
          ),
          Semantics(
            label: 'Close thread view',
            button: true,
            child: GestureDetector(
              onTap: widget.onClose,
              child: Icon(Icons.close, size: 18, color: context.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParentMessage(BuildContext context, ChatMessage parent) {
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
          Text(
            parent.content,
            style: TextStyle(fontSize: 14, color: context.textPrimary),
          ),
          if (_replies.isNotEmpty && !_isLoading) ...[
            const SizedBox(height: 8),
            Text(
              '${_replies.length} ${_replies.length == 1 ? 'reply' : 'replies'}',
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

  Widget _buildRepliesList(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: context.textMuted),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(fontSize: 13, color: context.textMuted),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadReplies, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_replies.isEmpty) {
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _replies.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final reply = _replies[index];
        return _buildReplyItem(context, reply);
      },
    );
  }

  Widget _buildReplyItem(BuildContext context, ChatMessage reply) {
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
              reply.replyToId != widget.parentMessage.id)
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
              color: isMine
                  ? context.accent.withValues(alpha: 0.1)
                  : context.chatBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              reply.content,
              style: TextStyle(fontSize: 13, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyAction(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: Semantics(
        label: 'Reply in thread',
        button: true,
        child: GestureDetector(
          onTap: () {
            widget.onReply?.call(widget.parentMessage);
            widget.onClose();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: context.chatBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.border),
            ),
            child: Row(
              children: [
                Icon(Icons.reply_outlined, size: 16, color: context.textMuted),
                const SizedBox(width: 8),
                Text(
                  'Reply in thread...',
                  style: TextStyle(fontSize: 13, color: context.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
}

/// Shows the thread view as a bottom sheet on mobile.
void showThreadBottomSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ChatMessage parentMessage,
  String? serverUrl,
  String? authToken,
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
          onReply: onReply,
          onClose: () => Navigator.pop(sheetContext),
        ),
      ),
    ),
  );
}
