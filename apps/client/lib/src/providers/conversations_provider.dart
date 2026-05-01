import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../services/debug_log_service.dart';
import '../services/message_cache.dart';
import '../services/notification_service.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'privacy_provider.dart';
import 'server_url_provider.dart';

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

class ConversationsNotifier extends StateNotifier<ConversationsState>
    with _ConversationsWsHandlersMixin, _ConversationsHttpActionsMixin {
  @override
  final Ref ref;

  /// Cache of decrypted message previews by conversationId.
  @override
  final Map<String, String> _decryptedPreviews = {};

  /// Monotonic generation counter for [loadConversations] (#515). Each
  /// call captures `++_loadGen` and bails before mutating state when
  /// the captured value no longer matches -- guards against a stale
  /// in-flight response (e.g. WS reconnect racing pull-to-refresh)
  /// overwriting fresh state.
  int _loadGen = 0;

  ConversationsNotifier(this.ref) : super(const ConversationsState());

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
  ) async {
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
      if (gen != _loadGen || !mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> list = body is List
            ? body
            : (body['conversations'] as List? ?? []);
        final conversations = list
            .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
            .toList();

        // Replace encrypted previews with cached decrypted text or placeholder
        for (var i = 0; i < conversations.length; i++) {
          final conv = conversations[i];
          if (conv.lastMessage != null && looksEncrypted(conv.lastMessage!)) {
            var cached = _decryptedPreviews[conv.id];
            if (cached == null) {
              cached = await MessageCache.getLatestCachedPreview(conv.id);
              if (cached != null) _decryptedPreviews[conv.id] = cached;
            }
            conversations[i] = conv.copyWith(
              lastMessage: cached ?? 'Encrypted message',
            );
          }
        }

        // Sort by last activity (most recent first)
        conversations.sort((a, b) {
          final aTime = a.lastMessageTimestamp ?? '';
          final bTime = b.lastMessageTimestamp ?? '';
          return bTime.compareTo(aTime);
        });

        state = state.copyWith(conversations: conversations, isLoading: false);
        _updateTabBadge();

        // Hydrate last-message status from Hive so conversation tiles show
        // the correct tick on cold start, before WS read_receipt events
        // arrive (#573). Fire-and-forget: failures are non-fatal.
        final myUserId = ref.read(authProvider).userId;
        if (myUserId != null) {
          final ids = conversations.map((c) => c.id).toList();
          ref
              .read(chatProvider.notifier)
              .hydrateStatusFromCache(ids, myUserId)
              .ignore();
        }
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load conversations',
        );
      }
    } catch (e) {
      // Stale errors must not clobber a fresh success, and writing to
      // `state` on a disposed notifier throws.
      if (gen != _loadGen || !mounted) return;
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }

  /// Mark a conversation as read (reset unread count).
  void markAsRead(String conversationId) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      updated[index] = updated[index].copyWith(unreadCount: 0);
      state = state.copyWith(conversations: updated);
      _updateTabBadge();
    }
  }

  /// Send read receipt to server.
  Future<void> sendReadReceipt(String conversationId) async {
    // Save old count so we can restore it if the server call fails.
    final oldCount =
        state.conversations
            .where((c) => c.id == conversationId)
            .firstOrNull
            ?.unreadCount ??
        0;

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
      // Rollback: restore the previous unread count so the badge reappears.
      if (oldCount > 0) {
        final rollback = List<Conversation>.from(state.conversations);
        final idx = rollback.indexWhere((c) => c.id == conversationId);
        if (idx >= 0) {
          rollback[idx] = rollback[idx].copyWith(unreadCount: oldCount);
          state = state.copyWith(conversations: rollback);
          _updateTabBadge();
        }
      }
    }
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, ConversationsState>((ref) {
      return ConversationsNotifier(ref);
    });

/// Thrown by [ConversationsNotifier.getOrCreateDm] when the server rejects
/// the request or a network error occurs. [message] is safe to display to
/// the user.
class DmException implements Exception {
  final String message;
  const DmException(this.message);

  @override
  String toString() => message;
}
