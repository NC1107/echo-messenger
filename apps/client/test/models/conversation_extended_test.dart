import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';

void main() {
  group('Conversation.fromJson', () {
    test('parses group conversation with members', () {
      final conv = Conversation.fromJson({
        'conversation_id': 'conv-1',
        'title': 'Dev Team',
        'kind': 'group',
        'description': 'Engineering team',
        'is_encrypted': true,
        'unread_count': 5,
        'is_muted': true,
        'members': [
          {'user_id': 'user-1', 'username': 'alice'},
          {'user_id': 'user-2', 'username': 'bob'},
        ],
      });

      expect(conv.id, 'conv-1');
      expect(conv.name, 'Dev Team');
      expect(conv.isGroup, isTrue);
      expect(conv.description, 'Engineering team');
      expect(conv.isEncrypted, isTrue);
      expect(conv.unreadCount, 5);
      expect(conv.isMuted, isTrue);
      expect(conv.members, hasLength(2));
    });

    test('parses direct conversation', () {
      final conv = Conversation.fromJson({
        'id': 'conv-2',
        'kind': 'direct',
        'members': [
          {'user_id': 'user-1', 'username': 'alice'},
          {'user_id': 'user-2', 'username': 'bob'},
        ],
      });

      expect(conv.id, 'conv-2');
      expect(conv.isGroup, isFalse);
    });

    test('parses last_message as object', () {
      final conv = Conversation.fromJson({
        'conversation_id': 'conv-1',
        'kind': 'direct',
        'last_message': {
          'content': 'Hello!',
          'created_at': '2026-01-01T10:00:00Z',
          'sender_username': 'alice',
        },
      });

      expect(conv.lastMessage, 'Hello!');
      expect(conv.lastMessageTimestamp, '2026-01-01T10:00:00Z');
      expect(conv.lastMessageSender, 'alice');
    });

    test('parses last_message as string', () {
      final conv = Conversation.fromJson({
        'conversation_id': 'conv-1',
        'kind': 'direct',
        'last_message': 'Quick message',
        'last_message_timestamp': '2026-01-01T10:00:00Z',
        'last_message_sender': 'bob',
      });

      expect(conv.lastMessage, 'Quick message');
      expect(conv.lastMessageTimestamp, '2026-01-01T10:00:00Z');
      expect(conv.lastMessageSender, 'bob');
    });

    test('handles legacy peer_user_id/peer_username format', () {
      final conv = Conversation.fromJson({
        'conversation_id': 'conv-1',
        'kind': 'direct',
        'peer_user_id': 'user-1',
        'peer_username': 'alice',
      });

      expect(conv.members, hasLength(1));
      expect(conv.members.first.userId, 'user-1');
      expect(conv.members.first.username, 'alice');
    });

    test('handles is_group as bool', () {
      final conv = Conversation.fromJson({
        'conversation_id': 'conv-1',
        'is_group': true,
      });
      expect(conv.isGroup, isTrue);
    });

    test('defaults for missing fields', () {
      final conv = Conversation.fromJson({'conversation_id': 'conv-1'});

      expect(conv.isGroup, isFalse);
      expect(conv.isEncrypted, isFalse);
      expect(conv.unreadCount, 0);
      expect(conv.isMuted, isFalse);
      expect(conv.members, isEmpty);
      expect(conv.lastMessage, isNull);
    });
  });

  group('Conversation.displayName', () {
    test('returns group name for groups', () {
      const conv = Conversation(
        id: 'conv-1',
        name: 'Dev Team',
        isGroup: true,
        members: [
          ConversationMember(userId: 'user-1', username: 'alice'),
          ConversationMember(userId: 'me', username: 'testuser'),
        ],
      );
      expect(conv.displayName('me'), 'Dev Team');
    });

    test('returns peer username for DMs', () {
      const conv = Conversation(
        id: 'conv-1',
        isGroup: false,
        members: [
          ConversationMember(userId: 'user-1', username: 'alice'),
          ConversationMember(userId: 'me', username: 'testuser'),
        ],
      );
      expect(conv.displayName('me'), 'alice');
    });

    test('returns Unknown when no members match', () {
      const conv = Conversation(id: 'conv-1', isGroup: false, members: []);
      expect(conv.displayName('me'), 'Unknown');
    });
  });

  group('Conversation.copyWith', () {
    test('preserves unchanged fields', () {
      const conv = Conversation(
        id: 'conv-1',
        name: 'Test',
        isGroup: true,
        unreadCount: 3,
        isMuted: true,
      );

      final copied = conv.copyWith(unreadCount: 5);
      expect(copied.id, 'conv-1');
      expect(copied.name, 'Test');
      expect(copied.isGroup, isTrue);
      expect(copied.unreadCount, 5);
      expect(copied.isMuted, isTrue);
    });
  });

  group('ConversationMember', () {
    test('fromJson parses all fields', () {
      final member = ConversationMember.fromJson({
        'user_id': 'user-1',
        'username': 'alice',
        'avatar_url': 'https://example.com/avatar.png',
        'role': 'admin',
      });

      expect(member.userId, 'user-1');
      expect(member.username, 'alice');
      expect(member.avatarUrl, 'https://example.com/avatar.png');
      expect(member.role, 'admin');
    });

    test('fromJson handles minimal fields', () {
      final member = ConversationMember.fromJson({
        'user_id': 'user-1',
        'username': 'bob',
      });

      expect(member.userId, 'user-1');
      expect(member.username, 'bob');
      expect(member.avatarUrl, isNull);
      expect(member.role, isNull);
    });

    test('equality works correctly', () {
      const m1 = ConversationMember(userId: 'u1', username: 'alice');
      const m2 = ConversationMember(userId: 'u1', username: 'alice');
      const m3 = ConversationMember(userId: 'u2', username: 'bob');

      expect(m1, equals(m2));
      expect(m1, isNot(equals(m3)));
    });
  });
}
