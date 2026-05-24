import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/conversation.dart';
import '../services/debug_log_service.dart';
import '../services/message_cache.dart';
import '../services/notification_service.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'crypto_provider.dart';
import 'privacy_provider.dart';
import 'server_url_provider.dart';

part 'conversations_provider.g.dart';
part 'conversations_ws_handlers.dart';
part 'conversations_http_actions.dart';

class ConversationsState {
  final List<Conversation> conversations;
  final bool isLoading;
  final String? error;

  const ConversationsState({
    this.conversations = const [],
    this.isLoading = false,
    this.error,
  });

  ConversationsState copyWith({
    List<Conversation>? conversations,
    bool? isLoading,
    String? error,
  }) {
    return ConversationsState(
      conversations: conversations ?? this.conversations,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

@Riverpod(keepAlive: true)
class ConversationsNotifier extends _$ConversationsNotifier
    with _ConversationsWsHandlersMixin, _ConversationsHttpActionsMixin {
  /// Cache of decrypted message previews by conversationId.
  @override
  final Map<String, String> _decryptedPreviews = {};

  /// Monotonic generation counter for [loadConversations] (#515). Each
  /// call captures `++_loadGen` and bails before mutating state when
  /// the captured value no longer matches -- guards against a stale
  /// in-flight response (e.g. WS reconnect racing pull-to-refresh)
  /// overwriting fresh state.
  int _loadGen = 0;

  /// Tracks notifier liveness so async callbacks can avoid touching `state`
  /// after disposal (codegen Notifier has no `mounted` getter the way
  /// StateNotifier did, so we maintain our own flag via `ref.onDispose`).
  bool _disposed = false;

  @override
  ConversationsState build() {
    ref.onDispose(() {
      _disposed = true;
    });
    return const ConversationsState();
  }

  /// Internal alias for the StateNotifier-era `mounted` getter.
  bool get _mounted => !_disposed;

  @override
  String get _serverUrl => ref.read(serverUrlProvider);

  /// Map raw exceptions to user-friendly error messages.
  @override
  String _friendlyError(Object error) {
    final msg = error.toString();
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'Unable to connect to server. Check your internet connection.';
    }
    if (msg.contains('TimeoutException')) {
      return 'Request timed out. Please try again.';
    }
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return 'Session expired. Please log in again.';
    }
    if (msg.contains('403') || msg.contains('Forbidden')) {
      return 'You don\'t have permission to do that.';
    }
    return 'Something went wrong. Please try again.';
  }

  /// Extract the `error` field from a JSON response body, or return [fallback].
  @override
  String _parseServerError(String body, String fallback) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        return data['error'] as String? ?? fallback;
      }
    } catch (_) {}
    return fallback;
  }

  @override
  Map<String, String> _headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Compute total unread count and update the browser tab badge.
  @override
  void _updateTabBadge() {
    final total = state.conversations.fold<int>(
      0,
      (sum, c) => sum + c.unreadCount,
    );
    NotificationService().updateTabBadge(total);
  }

  /// Make an authenticated request with automatic 401 refresh-and-retry.
  @override
  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) {
    return ref.read(authProvider.notifier).authenticatedRequest(requestFn);
  }

  /// Load all conversations from the server.
  ///
  /// Uses a monotonic generation counter (#515) so a stale in-flight
  /// response cannot overwrite fresh state when two reloads overlap
  /// (e.g. WS reconnect racing pull-to-refresh).  Latest call wins.
  @override
  Future<void> loadConversations() async {
    state = state.copyWith(isLoading: true, error: null);
    final gen = ++_loadGen;
    try {
      final response = await _authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/conversations'),
          headers: _headersWithToken(token),
        ),
      );
      // Drop a stale response (a newer call has been issued) before any
      // state mutation so we don't clobber fresh data with an old payload.
      // Also bail if the notifier was disposed while we were awaiting --
      // writing to `state` after dispose throws StateError.
      if (gen != _loadGen || !_mounted) return;

      if (response.statusCode == 200) {
        await _handleSuccessResponse(response);
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load conversations',
        );
      }
    } catch (e) {
      // Stale errors must not clobber a fresh success, and writing to
      // `state` on a disposed notifier throws.
      if (gen != _loadGen || !_mounted) return;
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }

  /// Parse, decrypt, sort, and persist conversations from a successful response.
  Future<void> _handleSuccessResponse(http.Response response) async {
    final body = jsonDecode(response.body);
    final List<dynamic> list = body is List
        ? body
        : (body['conversations'] as List? ?? []);
    final conversations = list
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();

    await _decryptPreviews(conversations);
    _sortByLastActivity(conversations);

    state = state.copyWith(conversations: conversations, isLoading: false);
    _updateTabBadge();
    await _hydrateStatusFromCache(conversations);
  }

  /// Replace encrypted previews with cached decrypted text or placeholder.
  Future<void> _decryptPreviews(List<Conversation> conversations) async {
    for (var i = 0; i < conversations.length; i++) {
      final conv = conversations[i];
      if (conv.lastMessage != null && looksEncrypted(conv.lastMessage!)) {
        var cached = _decryptedPreviews[conv.id];
        if (cached == null) {
          cached = await MessageCache.getLatestCachedPreview(conv.id);
          if (cached != null) _decryptedPreviews[conv.id] = cached;
        }
        // Use the same bracketed `[Encrypted]` placeholder the sidebar
        // widget renders for ciphertext snippets, so cold-start HTTP loads
        // and live WS updates show the same string instead of diverging
        // between "Encrypted message" and "[Encrypted]".
        conversations[i] = conv.copyWith(lastMessage: cached ?? '[Encrypted]');
      }
    }
  }

  /// Sort conversations by last activity (most recent first).
  void _sortByLastActivity(List<Conversation> conversations) {
    conversations.sort((a, b) {
      final aTime = a.lastMessageTimestamp ?? '';
      final bTime = b.lastMessageTimestamp ?? '';
      return bTime.compareTo(aTime);
    });
  }

  /// Hydrate last-message status from cache so conversation tiles show
  /// the correct tick on cold start, before WS read_receipt events arrive (#573).
  /// Fire-and-forget: failures are non-fatal.
  Future<void> _hydrateStatusFromCache(List<Conversation> conversations) async {
    final myUserId = ref.read(authProvider).userId;
    if (myUserId != null) {
      final ids = conversations.map((c) => c.id).toList();
      ref
          .read(chatProvider.notifier)
          .hydrateStatusFromCache(ids, myUserId)
          .ignore();
    }
  }

  /// Mark a conversation as read (reset unread + mention counts).
  void markAsRead(String conversationId) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      updated[index] = updated[index].copyWith(unreadCount: 0, mentionCount: 0);
      state = state.copyWith(conversations: updated);
      _updateTabBadge();
    }
  }

  /// Send read receipt to server.
  Future<void> sendReadReceipt(String conversationId) async {
    // Save old counts so we can restore them if the server call fails.
    final oldConv = state.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final oldUnread = oldConv?.unreadCount ?? 0;
    final oldMention = oldConv?.mentionCount ?? 0;

    markAsRead(conversationId);
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) {
      return;
    }
    try {
      await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/conversations/$conversationId/read'),
          headers: _headersWithToken(token),
        ),
      );
    } catch (e) {
      debugPrint(
        '[Conversations] sendReadReceipt failed for '
        '$conversationId: $e',
      );
      // Rollback: restore the previous counts so the badges reappear.
      if (oldUnread > 0 || oldMention > 0) {
        final rollback = List<Conversation>.from(state.conversations);
        final idx = rollback.indexWhere((c) => c.id == conversationId);
        if (idx >= 0) {
          rollback[idx] = rollback[idx].copyWith(
            unreadCount: oldUnread,
            mentionCount: oldMention,
          );
          state = state.copyWith(conversations: rollback);
          _updateTabBadge();
        }
      }
    }
  }
}

/// Back-compat alias preserving the legacy `conversationsProvider` symbol.
final conversationsProvider = conversationsNotifierProvider;

/// Thrown by [ConversationsNotifier.getOrCreateDm] when the server rejects
/// the request or a network error occurs. [message] is safe to display to
/// the user.
class DmException implements Exception {
  final String message;
  const DmException(this.message);

  @override
  String toString() => message;
}

/// Thrown by [ConversationsNotifier.createGroup] when the server rejects
/// the request or a network error occurs. [message] is safe to display to
/// the user.
class GroupException implements Exception {
  final String message;
  const GroupException(this.message);

  @override
  String toString() => message;
}
