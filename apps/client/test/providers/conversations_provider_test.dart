import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/models/conversation.dart';

void main() {
  group('ConversationsState', () {
    test('initial state has empty conversations and is not loading', () {
      const state = ConversationsState();
      expect(state.conversations, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith preserves conversations and isLoading', () {
      final state = const ConversationsState(
        conversations: [Conversation(id: 'c1', isGroup: false)],
        isLoading: true,
      );
      final copied = state.copyWith();
      expect(copied.conversations, hasLength(1));
      expect(copied.conversations.first.id, 'c1');
      expect(copied.isLoading, isTrue);
    });

    test('copyWith with no error argument clears error (by design)', () {
      final state = const ConversationsState(error: 'old error');
      // The copyWith uses direct assignment for error (not null-coalesce),
      // so calling copyWith() without error clears it.
      final copied = state.copyWith();
      expect(copied.error, isNull);
    });

    test('copyWith overrides conversations', () {
      const state = ConversationsState();
      final updated = state.copyWith(
        conversations: [
          const Conversation(id: 'c1', isGroup: false),
          const Conversation(id: 'c2', isGroup: true, name: 'Dev Team'),
        ],
      );
      expect(updated.conversations, hasLength(2));
      expect(updated.conversations[0].id, 'c1');
      expect(updated.conversations[1].id, 'c2');
    });

    test('copyWith overrides isLoading', () {
      const state = ConversationsState();
      final loading = state.copyWith(isLoading: true);
      expect(loading.isLoading, isTrue);
      final notLoading = loading.copyWith(isLoading: false);
      expect(notLoading.isLoading, isFalse);
    });

    test('copyWith sets and clears error', () {
      const state = ConversationsState();
      final withError = state.copyWith(error: 'Network error');
      expect(withError.error, 'Network error');
      // copyWith(error: null) clears the error because the field uses
      // direct assignment (not null-coalesce)
      final cleared = withError.copyWith(error: null);
      expect(cleared.error, isNull);
    });

    test('adding a conversation updates the list', () {
      const state = ConversationsState();
      const conv = Conversation(
        id: 'conv-1',
        isGroup: false,
        lastMessage: 'Hello',
        lastMessageTimestamp: '2026-01-15T10:30:00Z',
        lastMessageSender: 'alice',
        unreadCount: 0,
        members: [
          ConversationMember(userId: 'u1', username: 'alice'),
          ConversationMember(userId: 'u2', username: 'bob'),
        ],
      );
      final updated = state.copyWith(conversations: [conv]);
      expect(updated.conversations, hasLength(1));
      expect(updated.conversations.first.id, 'conv-1');
      expect(updated.conversations.first.lastMessage, 'Hello');
    });

    test('removing a conversation updates the list', () {
      final state = const ConversationsState(
        conversations: [
          Conversation(id: 'c1', isGroup: false),
          Conversation(id: 'c2', isGroup: true, name: 'Group'),
          Conversation(id: 'c3', isGroup: false),
        ],
      );
      final filtered = state.conversations.where((c) => c.id != 'c2').toList();
      final updated = state.copyWith(conversations: filtered);
      expect(updated.conversations, hasLength(2));
      expect(updated.conversations.every((c) => c.id != 'c2'), isTrue);
    });

    test('unread count tracking via copyWith on Conversation', () {
      const conv = Conversation(id: 'conv-1', isGroup: false, unreadCount: 0);
      expect(conv.unreadCount, 0);

      final withUnread = conv.copyWith(unreadCount: 5);
      expect(withUnread.unreadCount, 5);

      final reset = withUnread.copyWith(unreadCount: 0);
      expect(reset.unreadCount, 0);
    });

    test('conversation unread count increments correctly', () {
      const conv = Conversation(id: 'conv-1', isGroup: false, unreadCount: 2);

      // Simulate receiving a new message (increment unread)
      final bumped = conv.copyWith(unreadCount: conv.unreadCount + 1);
      expect(bumped.unreadCount, 3);
    });

    test('conversation list can be sorted by timestamp', () {
      final conversations = [
        const Conversation(
          id: 'c1',
          isGroup: false,
          lastMessageTimestamp: '2026-01-15T09:00:00Z',
        ),
        const Conversation(
          id: 'c2',
          isGroup: false,
          lastMessageTimestamp: '2026-01-15T12:00:00Z',
        ),
        const Conversation(
          id: 'c3',
          isGroup: false,
          lastMessageTimestamp: '2026-01-15T06:00:00Z',
        ),
      ];

      // Sort by most recent first (same logic as provider)
      conversations.sort((a, b) {
        final aTime = a.lastMessageTimestamp ?? '';
        final bTime = b.lastMessageTimestamp ?? '';
        return bTime.compareTo(aTime);
      });

      expect(conversations[0].id, 'c2');
      expect(conversations[1].id, 'c1');
      expect(conversations[2].id, 'c3');
    });

    test('conversation mute state is preserved in copyWith', () {
      const conv = Conversation(id: 'c1', isGroup: false, isMuted: false);
      final muted = conv.copyWith(isMuted: true);
      expect(muted.isMuted, isTrue);
      final unmuted = muted.copyWith(isMuted: false);
      expect(unmuted.isMuted, isFalse);
    });
  });
}
