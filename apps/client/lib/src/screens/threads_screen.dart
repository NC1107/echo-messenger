import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/participated_thread.dart';
import '../providers/conversations_provider.dart';
import '../providers/participated_threads_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/crypto_utils.dart';
import '../utils/time_utils.dart';
import '../widgets/empty_state.dart';

/// Aggregate "Threads" screen (#449): lists every thread the user has
/// participated in across all conversations.
///
/// Tapping a row notifies the host (sidebar / home screen) via
/// [onOpenThread] which is expected to navigate to the conversation AND
/// open the thread panel scoped to the given parent message.
class ThreadsScreen extends ConsumerStatefulWidget {
  /// Called when the user taps a thread card. Receives the conversation
  /// id and the parent-message id so the host can open the chat and
  /// surface the thread panel.
  final void Function(String conversationId, String parentMessageId)?
  onOpenThread;

  const ThreadsScreen({super.key, this.onOpenThread});

  @override
  ConsumerState<ThreadsScreen> createState() => _ThreadsScreenState();
}

class _ThreadsScreenState extends ConsumerState<ThreadsScreen> {
  @override
  void initState() {
    super.initState();
    // Kick off the initial fetch on the next frame so the provider is
    // not mutated synchronously from build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(participatedThreadsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final stateData = ref.watch(participatedThreadsProvider);
    return Scaffold(
      backgroundColor: context.chatBg,
      appBar: AppBar(
        backgroundColor: context.surface,
        elevation: 0,
        title: Text(
          'Threads',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: IconThemeData(color: context.textSecondary),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: context.border),
        ),
      ),
      body: _buildBody(stateData),
    );
  }

  Widget _buildBody(ParticipatedThreadsState data) {
    if (data.isLoading && data.threads.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data.error != null && data.threads.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load threads.\n${data.error}',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textMuted, fontSize: 13),
          ),
        ),
      );
    }
    if (data.threads.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        title: 'No threads yet',
        body:
            'Reply to a message or get mentioned in a thread '
            'and it will show up here.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(participatedThreadsProvider.notifier).refresh(),
      color: context.accent,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: data.threads.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: context.border,
          indent: 16,
          endIndent: 16,
        ),
        itemBuilder: (context, index) {
          final thread = data.threads[index];
          return _ThreadCard(
            thread: thread,
            conversationLabel: _conversationLabel(thread.conversationId),
            onTap: widget.onOpenThread == null
                ? null
                : () => widget.onOpenThread!(
                    thread.conversationId,
                    thread.parentMessageId,
                  ),
          );
        },
      ),
    );
  }

  /// Resolve a friendly conversation label by looking up the conversation
  /// list. Falls back to the raw id when the conversation isn't loaded
  /// (e.g. the threads endpoint surfaced a thread from a stale conv).
  String _conversationLabel(String conversationId) {
    final convs = ref.read(conversationsProvider).conversations;
    final match = convs.where((c) => c.id == conversationId).firstOrNull;
    if (match == null) return conversationId;
    final myUserId = match.members.isNotEmpty
        ? match.members.first.userId
        : null;
    // Conversation.displayName needs the calling user id; we only need a
    // best-effort label here so an empty string is acceptable when the
    // user isn't a member (shouldn't happen given the server filter).
    return match.displayName(myUserId ?? '');
  }
}

/// One row of the threads list. Pulled into its own widget so the
/// cognitive complexity of `_buildBody` stays comfortably under the S3776
/// budget.
class _ThreadCard extends StatelessWidget {
  final ParticipatedThread thread;
  final String conversationLabel;
  final VoidCallback? onTap;

  const _ThreadCard({
    required this.thread,
    required this.conversationLabel,
    required this.onTap,
  });

  /// Decide how to render the parent preview: encrypted blobs get the
  /// `[Encrypted]` placeholder; plaintext is rendered verbatim. We don't
  /// attempt session decryption here — the chat panel does that on open.
  String _displayPreview() {
    final raw = thread.parentPreview;
    if (raw == null || raw.isEmpty) return '[No preview]';
    if (looksEncrypted(raw)) return '[Encrypted]';
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final ts = formatConversationTimestamp(
      thread.lastReplyAt.toIso8601String(),
    );
    final unread = thread.unreadReplyCount > 0;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(
                Icons.forum_outlined,
                size: 18,
                color: unread ? context.accent : context.textMuted,
              ),
            ),
            Expanded(child: _buildBody(context, ts, unread)),
            if (unread)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 6),
                child: Container(
                  key: const ValueKey('thread-unread-dot'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: context.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, String ts, bool unread) {
    final sender = thread.parentSenderUsername ?? 'Unknown';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                sender,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'in $conversationLabel',
                style: TextStyle(fontSize: 12, color: context.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            Text(ts, style: TextStyle(fontSize: 11, color: context.textMuted)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _displayPreview(),
          style: TextStyle(fontSize: 14, color: context.textSecondary),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        _buildFooter(context, unread),
      ],
    );
  }

  Widget _buildFooter(BuildContext context, bool unread) {
    final replyText = thread.replyCount == 1
        ? '1 reply'
        : '${thread.replyCount} replies';
    final lastSender = thread.lastReplySenderUsername;
    return Row(
      children: [
        Icon(
          Icons.reply_outlined,
          size: 14,
          color: unread ? context.accent : context.textMuted,
        ),
        const SizedBox(width: 4),
        Text(
          replyText,
          style: TextStyle(
            fontSize: 12,
            color: unread ? context.accent : context.textMuted,
            fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        if (lastSender != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '· last from $lastSender',
              style: TextStyle(fontSize: 12, color: context.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
