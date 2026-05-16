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

    test(
      'REST-style canonical field names take precedence over WS aliases',
      () {
        // #834: MessageDto no longer carries the legacy `message_id`,
        // `from_user_id`, `from_username` aliases. WS events still use
        // them, but in any blob that carries both the canonical REST keys
        // are the authoritative source — so when both are present (e.g.
        // a relay payload that gets reused as a history entry), REST
        // wins.
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

        expect(msg.id, 'rest-id');
        expect(msg.fromUserId, 'rest-user');
        expect(msg.fromUsername, 'rest-name');
        expect(msg.timestamp, '2026-03-31T15:00:00Z');
      },
    );

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

    test(
      'member_joined sentinel shows "You joined" when current user joined',
      () {
        const myUuid = '22222222-2222-2222-2222-222222222222';
        final json = {
          'message_id': 'msg-sys-me',
          'from_user_id': myUuid,
          'from_username': 'alice',
          'conversation_id': 'conv-1',
          'content': '__system__:member_joined:$myUuid:alice',
          'timestamp': '2026-04-01T10:00:00Z',
        };

        final msg = ChatMessage.fromServerJson(json, myUuid);

        expect(msg.isSystemEvent, isTrue);
        expect(msg.content, 'You joined the group');
      },
    );

    test('member_left sentinel translates to "X left the group"', () {
      final json = {
        'message_id': 'msg-left',
        'from_user_id': '33333333-3333-3333-3333-333333333333',
        'from_username': 'bob',
        'conversation_id': 'conv-1',
        'content':
            '__system__:member_left:33333333-3333-3333-3333-333333333333:bob',
        'timestamp': '2026-04-01T10:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-me');

      expect(msg.isSystemEvent, isTrue);
      expect(msg.content, 'bob left the group');
    });

    test('member_left sentinel shows "You left" when current user left', () {
      const myUuid = '44444444-4444-4444-4444-444444444444';
      final json = {
        'message_id': 'msg-left-me',
        'from_user_id': myUuid,
        'from_username': 'me',
        'conversation_id': 'conv-1',
        'content': '__system__:member_left:$myUuid:me',
        'timestamp': '2026-04-01T10:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, myUuid);

      expect(msg.isSystemEvent, isTrue);
      expect(msg.content, 'You left the group');
    });

    test(
      'member_removed sentinel translates to "X was removed from the group"',
      () {
        final json = {
          'message_id': 'msg-removed',
          'from_user_id': '55555555-5555-5555-5555-555555555555',
          'from_username': 'carol',
          'conversation_id': 'conv-1',
          'content':
              '__system__:member_removed:55555555-5555-5555-5555-555555555555:carol',
          'timestamp': '2026-04-01T10:00:00Z',
        };

        final msg = ChatMessage.fromServerJson(json, 'user-me');

        expect(msg.isSystemEvent, isTrue);
        expect(msg.content, 'carol was removed from the group');
      },
    );

    test(
      'member_removed sentinel shows "You were removed" for current user',
      () {
        const myUuid = '66666666-6666-6666-6666-666666666666';
        final json = {
          'message_id': 'msg-removed-me',
          'from_user_id': myUuid,
          'from_username': 'me',
          'conversation_id': 'conv-1',
          'content': '__system__:member_removed:$myUuid:me',
          'timestamp': '2026-04-01T10:00:00Z',
        };

        final msg = ChatMessage.fromServerJson(json, myUuid);

        expect(msg.isSystemEvent, isTrue);
        expect(msg.content, 'You were removed from the group');
      },
    );

    test(
      'member_banned sentinel translates to "X was banned from the group"',
      () {
        final json = {
          'message_id': 'msg-banned',
          'from_user_id': '77777777-7777-7777-7777-777777777777',
          'from_username': 'dave',
          'conversation_id': 'conv-1',
          'content':
              '__system__:member_banned:77777777-7777-7777-7777-777777777777:dave',
          'timestamp': '2026-04-01T10:00:00Z',
        };

        final msg = ChatMessage.fromServerJson(json, 'user-me');

        expect(msg.isSystemEvent, isTrue);
        expect(msg.content, 'dave was banned from the group');
      },
    );

    test('member_banned sentinel shows "You were banned" for current user', () {
      const myUuid = '88888888-8888-8888-8888-888888888888';
      final json = {
        'message_id': 'msg-banned-me',
        'from_user_id': myUuid,
        'from_username': 'me',
        'conversation_id': 'conv-1',
        'content': '__system__:member_banned:$myUuid:me',
        'timestamp': '2026-04-01T10:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, myUuid);

      expect(msg.isSystemEvent, isTrue);
      expect(msg.content, 'You were banned from the group');
    });

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

    // Regression: Hive returns nested maps as Map<dynamic, dynamic>, not
    // Map<String, dynamic>.  A direct `as Map<String, dynamic>` cast on each
    // reaction entry throws a TypeError on every conversation open in
    // production iOS (#ios-hive-map-cast).
    test(
      'reactions survive Hive Map<dynamic,dynamic> round-trip without crashing',
      () {
        // Simulate what Hive hands back after decoding a stored JSON blob:
        // the top-level map has been shallow-converted by MessageCache
        // (Map<String, dynamic>.from(raw)), but each element inside the
        // 'reactions' list is still Map<dynamic, dynamic>.
        final hiveReaction = <dynamic, dynamic>{
          'message_id': 'msg-1',
          'user_id': 'user-xyz',
          'username': 'bob',
          'emoji': '👍',
        };
        final json = <String, dynamic>{
          'message_id': 'msg-1',
          'from_user_id': 'user-abc',
          'from_username': 'alice',
          'conversation_id': 'conv-1',
          'content': 'hello',
          'timestamp': '2026-03-31T12:00:00Z',
          'reactions': [hiveReaction],
        };

        // Must not throw '_Map<dynamic, dynamic>' is not a subtype of
        // 'Map<String, dynamic>' in type cast.
        final msg = ChatMessage.fromServerJson(json, 'user-abc');

        expect(msg.reactions, hasLength(1));
        expect(msg.reactions.first.emoji, '👍');
        expect(msg.reactions.first.userId, 'user-xyz');
      },
    );

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
