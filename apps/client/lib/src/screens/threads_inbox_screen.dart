/// Cross-group threads inbox (Slack-style).
///
/// Lists every thread the user can see, newest reply first, with
/// per-row unread counts. Tapping a row routes to the parent
/// conversation and opens the thread panel anchored at the root.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/thread_inbox_entry.dart';
import '../providers/threads_inbox_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/window_chrome.dart';

class ThreadsInboxScreen extends ConsumerStatefulWidget {
  const ThreadsInboxScreen({super.key});

  @override
  ConsumerState<ThreadsInboxScreen> createState() => _ThreadsInboxScreenState();
}

class _ThreadsInboxScreenState extends ConsumerState<ThreadsInboxScreen> {
  @override
  void initState() {
    super.initState();
    // Fire-and-forget initial fetch. State is keep-alive so a return
    // visit doesn't refetch unless the user pulls to refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(threadsInboxProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(threadsInboxProvider);
    return Scaffold(
      backgroundColor: context.mainBg,
      body: Column(
        children: [
          const AppTitleBar(title: 'Threads'),
          _buildHeader(context),
          Expanded(child: _buildBody(context, inbox)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, color: context.textPrimary, size: 22),
          const SizedBox(width: 10),
          Text(
            'Threads',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh, color: context.textSecondary, size: 18),
            onPressed: () => ref.read(threadsInboxProvider.notifier).load(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThreadsInboxState inbox) {
    if (inbox.loading && inbox.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (inbox.error != null && inbox.entries.isEmpty) {
      return _buildErrorState(context, inbox.error!);
    }
    if (inbox.entries.isEmpty) {
      return _buildEmptyState(context);
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(threadsInboxProvider.notifier).load(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: inbox.entries.length,
        itemBuilder: (context, index) {
          final entry = inbox.entries[index];
          return _ThreadInboxRow(
            entry: entry,
            onTap: () => _openThread(context, entry),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: context.textMuted),
            const SizedBox(height: 16),
            Text(
              'No threads yet',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Reply to a message in thread and it will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: context.textMuted),
            const SizedBox(height: 16),
            Text(
              "Couldn't load threads",
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.read(threadsInboxProvider.notifier).load(),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  void _openThread(BuildContext context, ThreadInboxEntry entry) {
    // Mark read locally + on the server before routing so the badge
    // updates immediately.
    ref.read(threadsInboxProvider.notifier).markRead(entry.threadRootId);
    // Route the user to the parent conversation; the thread panel is
    // surfaced from the message itself. Deep-link via a query param so
    // HomeScreen can auto-open the thread on land.
    context.go(
      '/home'
      '?conversation=${entry.conversationId}'
      '&thread=${entry.threadRootId}',
    );
  }
}

class _ThreadInboxRow extends StatelessWidget {
  const _ThreadInboxRow({required this.entry, required this.onTap});

  final ThreadInboxEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: context.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 20,
                color: entry.isUnread ? context.accent : context.textMuted,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.parentSenderUsername,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _formatAgo(entry.lastReplyAt),
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.parentExcerpt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${entry.lastReplySenderUsername}: '
                      '${entry.lastReplyExcerpt}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '${entry.replyCount} '
                          '${entry.replyCount == 1 ? "reply" : "replies"}',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (entry.isUnread) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.accent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${entry.unreadCount} new',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatAgo(DateTime when) {
    final delta = DateTime.now().toUtc().difference(when.toUtc());
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${(delta.inDays / 7).floor()}w ago';
  }
}
