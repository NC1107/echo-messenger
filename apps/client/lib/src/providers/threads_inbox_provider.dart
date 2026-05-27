/// Cross-group threads inbox state + mark-read + nav-rail unread count.
///
/// Backed by three REST endpoints landed in threads M3:
///   GET  /api/threads/inbox         → ThreadInboxEntry[]
///   POST /api/messages/:id/thread/read
///   GET  /api/threads/unread-count  → { count }
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/thread_inbox_entry.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

part 'threads_inbox_provider.g.dart';

/// Snapshot of the threads-inbox screen.
@immutable
class ThreadsInboxState {
  final List<ThreadInboxEntry> entries;
  final bool loading;
  final String? error;

  const ThreadsInboxState({
    this.entries = const [],
    this.loading = false,
    this.error,
  });

  ThreadsInboxState copyWith({
    List<ThreadInboxEntry>? entries,
    bool? loading,
    Object? error = _sentinel,
  }) {
    return ThreadsInboxState(
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
      error: error == _sentinel ? this.error : error as String?,
    );
  }
}

const _sentinel = Object();

@Riverpod(keepAlive: true)
class ThreadsInbox extends _$ThreadsInbox {
  @override
  ThreadsInboxState build() => const ThreadsInboxState();

  /// Pull fresh inbox rows. Called on first sidebar-Threads click and
  /// whenever the user pulls to refresh.
  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/threads/inbox'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (response.statusCode != 200) {
        state = state.copyWith(
          loading: false,
          error: 'Server returned ${response.statusCode}',
        );
        return;
      }
      final raw = jsonDecode(response.body) as List;
      final entries = raw
          .map((e) => ThreadInboxEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(loading: false, entries: entries, error: null);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Mark a thread read on the server AND in the local cache so the
  /// inbox row + chip badge update immediately (don't wait for a
  /// refetch).
  Future<void> markRead(String threadRootId) async {
    // Optimistic local update.
    final updated = state.entries.map((e) {
      if (e.threadRootId != threadRootId) return e;
      return ThreadInboxEntry(
        threadRootId: e.threadRootId,
        conversationId: e.conversationId,
        channelId: e.channelId,
        parentSenderUsername: e.parentSenderUsername,
        parentExcerpt: e.parentExcerpt,
        lastReplyAt: e.lastReplyAt,
        lastReplyExcerpt: e.lastReplyExcerpt,
        lastReplySenderUsername: e.lastReplySenderUsername,
        replyCount: e.replyCount,
        unreadCount: 0,
      );
    }).toList();
    state = state.copyWith(entries: updated);

    try {
      final serverUrl = ref.read(serverUrlProvider);
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/messages/$threadRootId/thread/read'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
    } catch (_) {
      // Best-effort: a failed POST leaves the optimistic state. Next
      // inbox refresh will re-derive the truth from the server.
    }

    // Refresh the nav-rail badge.
    unawaited(ref.read(unreadThreadCountProvider.notifier).refresh());
  }
}

/// Aggregated unread-threads number for the nav-rail badge. Polled on
/// app focus + after each markRead.
@Riverpod(keepAlive: true)
class UnreadThreadCount extends _$UnreadThreadCount {
  @override
  int build() {
    // Initial fetch is fire-and-forget; UI renders 0 until it lands.
    Future.microtask(refresh);
    return 0;
  }

  Future<void> refresh() async {
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/threads/unread-count'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (response.statusCode != 200) return;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      state = (body['count'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Best-effort badge; silent failure is acceptable.
    }
  }
}

// Generated symbols (`threadsInboxProvider` + `unreadThreadCountProvider`)
// are exported directly from the `.g.dart` part; no manual aliases here.
