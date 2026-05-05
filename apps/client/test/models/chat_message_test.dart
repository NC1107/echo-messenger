import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  group('ChatMessage.fromServerJson', () {
    test('own message sets isMine=true', () {
      final json = {
        'message_id': 'msg-1',
        'from_user_id': 'user-abc',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': 'hello',
        'timestamp': '2026-03-31T12:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');

      expect(msg.isMine, isTrue);
    });

    test('peer message sets isMine=false', () {
      final json = {
        'message_id': 'msg-2',
        'from_user_id': 'user-xyz',
        'from_username': 'bob',
        'conversation_id': 'conv-1',
        'content': 'hey there',
        'timestamp': '2026-03-31T12:01:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');

      expect(msg.isMine, isFalse);
    });

    test('all fields parsed correctly', () {
      final json = {
        'message_id': 'msg-42',
        'from_user_id': 'user-sender',
        'from_username': 'sender_name',
        'conversation_id': 'conv-99',
        'content': 'full field test',
        'timestamp': '2026-03-31T15:30:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-me');

      expect(msg.id, 'msg-42');
      expect(msg.fromUserId, 'user-sender');
      expect(msg.fromUsername, 'sender_name');
      expect(msg.conversationId, 'conv-99');
      expect(msg.content, 'full field test');
      expect(msg.timestamp, '2026-03-31T15:30:00Z');
      expect(msg.isMine, isFalse);
      expect(msg.status, MessageStatus.sent);
      expect(msg.reactions, isEmpty);
    });

    test('default status is sent', () {
      final json = {
        'message_id': 'msg-1',
        'from_user_id': 'user-abc',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': 'hello',
        'timestamp': '2026-03-31T12:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');
      expect(msg.status, MessageStatus.sent);
    });

    test('reactions parsed from json', () {
      final json = {
        'message_id': 'msg-1',
        'from_user_id': 'user-abc',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': 'hello',
        'timestamp': '2026-03-31T12:00:00Z',
        'reactions': [
          {
            'message_id': 'msg-1',
            'user_id': 'user-xyz',
            'username': 'bob',
            'emoji': '👍',
          },
        ],
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');
      expect(msg.reactions, hasLength(1));
      expect(msg.reactions.first.emoji, '👍');
      expect(msg.reactions.first.userId, 'user-xyz');
    });

    test('REST-style field names parsed via fallbacks', () {
      final json = {
        'id': 'msg-rest-1',
        'sender_id': 'user-rest',
        'sender_username': 'rest_user',
        'conversation_id': 'conv-1',
        'content': 'from REST API',
        'created_at': '2026-03-31T14:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-other');

      expect(msg.id, 'msg-rest-1');
      expect(msg.fromUserId, 'user-rest');
      expect(msg.fromUsername, 'rest_user');
      expect(msg.timestamp, '2026-03-31T14:00:00Z');
      expect(msg.isMine, isFalse);
    });

    test('REST-style isMine detection with sender_id', () {
      final json = {
        'id': 'msg-rest-2',
        'sender_id': 'user-me',
        'sender_username': 'me',
        'conversation_id': 'conv-1',
        'content': 'my message',
        'created_at': '2026-03-31T14:01:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-me');

      expect(msg.isMine, isTrue);
    });

    test('WS-style field names take precedence over REST-style', () {
      final json = {
        'message_id': 'ws-id',
        'id': 'rest-id',
        'from_user_id': 'ws-user',
        'sender_id': 'rest-user',
        'from_username': 'ws-name',
        'sender_username': 'rest-name',
        'conversation_id': 'conv-1',
        'content': 'test',
        'timestamp': '2026-03-31T15:00:00Z',
        'created_at': '2026-03-31T14:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'other');

      expect(msg.id, 'ws-id');
      expect(msg.fromUserId, 'ws-user');
      expect(msg.fromUsername, 'ws-name');
      expect(msg.timestamp, '2026-03-31T15:00:00Z');
    });

    test('copyWith to decrypt-failure preserves identity fields', () {
      const msg = ChatMessage(
        id: 'msg-enc-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'SGVsbG8gV29ybGQ=',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      final failed = msg.copyWith(content: '[Could not decrypt]');

      expect(failed.content, '[Could not decrypt]');
      expect(failed.id, 'msg-enc-1');
      expect(failed.fromUserId, 'user-1');
      expect(failed.fromUsername, 'alice');
      expect(failed.conversationId, 'conv-1');
      expect(failed.timestamp, '2026-03-31T12:00:00Z');
    });

    test('copyWith preserves unchanged fields', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
        status: MessageStatus.sending,
      );

      final updated = msg.copyWith(status: MessageStatus.sent);

      expect(updated.id, 'msg-1');
      expect(updated.content, 'hello');
      expect(updated.status, MessageStatus.sent);
      expect(updated.isMine, isTrue);
    });

    test('value equality compares content and reactions', () {
      const reaction = Reaction(
        messageId: 'msg-1',
        userId: 'user-2',
        username: 'bob',
        emoji: '👍',
      );
      const first = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
        reactions: [reaction],
      );
      const second = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
        reactions: [reaction],
      );

      expect(first, equals(second));
      expect(first.hashCode, equals(second.hashCode));
    });

    test(
      'historical __system__:member_joined sentinel becomes a system event',
      () {
        // Server persists the join row with the joiner's UUID as sender_id and
        // the raw sentinel as content (#663). On HTTP history load we have to
        // translate it back into a system event so the chat panel renders the
        // pill instead of a literal-text bubble.
        final json = {
          'message_id': 'msg-sys',
          'from_user_id': '11111111-1111-1111-1111-111111111111',
          'from_username': 'alice',
          'conversation_id': 'conv-1',
          'content':
              '__system__:member_joined:11111111-1111-1111-1111-111111111111:alice',
          'timestamp': '2026-04-01T10:00:00Z',
        };

        final msg = ChatMessage.fromServerJson(json, 'user-me');

        expect(msg.isSystemEvent, isTrue);
        expect(msg.fromUserId, ChatMessage.systemUserId);
        expect(msg.content, 'alice joined the group');
      },
    );

    test('non-system content is left untouched', () {
      final json = {
        'message_id': 'msg-1',
        'from_user_id': 'user-abc',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': '__system__:unknown_kind:abc',
        'timestamp': '2026-04-01T10:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-me');

      // Unknown sentinels stay untouched so we don't silently drop new
      // server-side event kinds.
      expect(msg.isSystemEvent, isFalse);
      expect(msg.content, '__system__:unknown_kind:abc');
    });

    test('value equality differs when key field changes', () {
      const first = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
      );
      const second = ChatMessage(
        id: 'msg-2',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
      );

      expect(first == second, isFalse);
    });
  });
}
