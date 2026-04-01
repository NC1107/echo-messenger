import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/conversation.dart';

void main() {
  group('Conversation', () {
    test('fromJson parses 1:1 conversation', () {
      final json = {
        'conversation_id': 'conv-1',
        'name': null,
        'is_group': false,
        'last_message': 'hello',
        'last_message_timestamp': '2026-03-31T12:00:00Z',
        'last_message_sender': 'alice',
        'unread_count': 2,
        'members': [
          {'user_id': 'user-1', 'username': 'alice'},
          {'user_id': 'user-2', 'username': 'bob'},
        ],
      };

      final conv = Conversation.fromJson(json);

      expect(conv.id, 'conv-1');
      expect(conv.isGroup, isFalse);
      expect(conv.lastMessage, 'hello');
      expect(conv.unreadCount, 2);
      expect(conv.members, hasLength(2));
    });

    test('fromJson parses group conversation', () {
      final json = {
        'conversation_id': 'conv-2',
        'name': 'Team Chat',
        'is_group': true,
        'last_message': 'hi team',
        'last_message_timestamp': '2026-03-31T13:00:00Z',
        'last_message_sender': 'carol',
        'unread_count': 0,
        'members': [
          {'user_id': 'user-1', 'username': 'alice'},
          {'user_id': 'user-2', 'username': 'bob'},
          {'user_id': 'user-3', 'username': 'carol'},
        ],
      };

      final conv = Conversation.fromJson(json);

      expect(conv.id, 'conv-2');
      expect(conv.name, 'Team Chat');
      expect(conv.isGroup, isTrue);
      expect(conv.members, hasLength(3));
    });

    test('displayName shows group name for groups', () {
      final conv = Conversation(
        id: 'conv-1',
        name: 'Team Chat',
        isGroup: true,
        members: const [
          ConversationMember(userId: 'user-1', username: 'alice'),
          ConversationMember(userId: 'user-2', username: 'bob'),
        ],
      );

      expect(conv.displayName('user-1'), 'Team Chat');
    });

    test('displayName shows peer name for 1:1', () {
      final conv = Conversation(
        id: 'conv-1',
        isGroup: false,
        members: const [
          ConversationMember(userId: 'user-1', username: 'alice'),
          ConversationMember(userId: 'user-2', username: 'bob'),
        ],
      );

      expect(conv.displayName('user-1'), 'bob');
      expect(conv.displayName('user-2'), 'alice');
    });

    test('copyWith updates specified fields', () {
      final conv = Conversation(
        id: 'conv-1',
        name: 'Old Name',
        isGroup: true,
        unreadCount: 5,
      );

      final updated = conv.copyWith(unreadCount: 0);

      expect(updated.id, 'conv-1');
      expect(updated.name, 'Old Name');
      expect(updated.unreadCount, 0);
    });

    test('fromJson uses id fallback when conversation_id missing', () {
      final json = {
        'id': 'conv-fallback',
        'is_group': false,
        'members': <Map<String, dynamic>>[],
      };

      final conv = Conversation.fromJson(json);
      expect(conv.id, 'conv-fallback');
    });
  });

  group('ConversationMember', () {
    test('fromJson parses correctly', () {
      final json = {'user_id': 'user-1', 'username': 'alice'};

      final member = ConversationMember.fromJson(json);

      expect(member.userId, 'user-1');
      expect(member.username, 'alice');
    });
  });
}
