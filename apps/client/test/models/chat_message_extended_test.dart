import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  group('ChatMessage.copyWith', () {
    const base = ChatMessage(
      id: 'msg-1',
      fromUserId: 'user-1',
      fromUsername: 'alice',
      conversationId: 'conv-1',
      content: 'Hello',
      timestamp: '2026-01-01T00:00:00Z',
      isMine: false,
    );

    test('preserves all fields when no args passed', () {
      final copy = base.copyWith();
      expect(copy, equals(base));
    });

    test('updates content', () {
      final copy = base.copyWith(content: 'Updated');
      expect(copy.content, 'Updated');
      expect(copy.id, 'msg-1');
    });

    test('updates status', () {
      final copy = base.copyWith(status: MessageStatus.delivered);
      expect(copy.status, MessageStatus.delivered);
    });

    test('updates isEncrypted', () {
      final copy = base.copyWith(isEncrypted: true);
      expect(copy.isEncrypted, isTrue);
    });

    test('sets pinnedById using sentinel pattern', () {
      final pinned = base.copyWith(
        pinnedById: 'user-2',
        pinnedAt: DateTime(2026, 1, 1),
      );
      expect(pinned.pinnedById, 'user-2');
      expect(pinned.pinnedAt, isNotNull);

      // Can also set to null explicitly
      final unpinned = pinned.copyWith(pinnedById: null, pinnedAt: null);
      expect(unpinned.pinnedById, isNull);
      expect(unpinned.pinnedAt, isNull);
    });

    test('sets failedContent using sentinel pattern', () {
      final failed = base.copyWith(failedContent: 'original text');
      expect(failed.failedContent, 'original text');

      final cleared = failed.copyWith(failedContent: null);
      expect(cleared.failedContent, isNull);
    });

    test('updates reactions', () {
      final copy = base.copyWith(
        reactions: [
          const Reaction(
            messageId: 'msg-1',
            userId: 'user-2',
            username: 'bob',
            emoji: '👍',
          ),
        ],
      );
      expect(copy.reactions, hasLength(1));
    });

    test('updates reply fields', () {
      final copy = base.copyWith(
        replyToId: 'msg-0',
        replyToContent: 'Original',
        replyToUsername: 'bob',
      );
      expect(copy.replyToId, 'msg-0');
      expect(copy.replyToContent, 'Original');
      expect(copy.replyToUsername, 'bob');
    });

    test('updates channelId', () {
      final copy = base.copyWith(channelId: 'ch-1');
      expect(copy.channelId, 'ch-1');
    });

    test('updates editedAt', () {
      final copy = base.copyWith(editedAt: '2026-01-02T00:00:00Z');
      expect(copy.editedAt, '2026-01-02T00:00:00Z');
    });
  });

  group('ChatMessage equality', () {
    const msg1 = ChatMessage(
      id: 'msg-1',
      fromUserId: 'user-1',
      fromUsername: 'alice',
      conversationId: 'conv-1',
      content: 'Hello',
      timestamp: '2026-01-01T00:00:00Z',
      isMine: false,
    );

    const msg1Copy = ChatMessage(
      id: 'msg-1',
      fromUserId: 'user-1',
      fromUsername: 'alice',
      conversationId: 'conv-1',
      content: 'Hello',
      timestamp: '2026-01-01T00:00:00Z',
      isMine: false,
    );

    const msg2 = ChatMessage(
      id: 'msg-2',
      fromUserId: 'user-1',
      fromUsername: 'alice',
      conversationId: 'conv-1',
      content: 'Different',
      timestamp: '2026-01-01T00:01:00Z',
      isMine: false,
    );

    test('identical messages are equal', () {
      expect(msg1, equals(msg1Copy));
    });

    test('different messages are not equal', () {
      expect(msg1, isNot(equals(msg2)));
    });

    test('hashCode matches for equal messages', () {
      expect(msg1.hashCode, equals(msg1Copy.hashCode));
    });

    test('hashCode differs for different messages', () {
      expect(msg1.hashCode, isNot(equals(msg2.hashCode)));
    });
  });

  group('ChatMessage.fromServerJson', () {
    test('handles message_id and id keys', () {
      final withMessageId = ChatMessage.fromServerJson({
        'message_id': 'msg-1',
        'from_user_id': 'u1',
        'from_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
      }, 'u1');
      expect(withMessageId.id, 'msg-1');

      final withId = ChatMessage.fromServerJson({
        'id': 'msg-2',
        'from_user_id': 'u1',
        'from_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
      }, 'u1');
      expect(withId.id, 'msg-2');
    });

    test('handles sender_id and sender_username keys', () {
      final msg = ChatMessage.fromServerJson({
        'id': 'msg-1',
        'sender_id': 'u1',
        'sender_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
      }, 'u1');
      expect(msg.fromUserId, 'u1');
      expect(msg.fromUsername, 'alice');
      expect(msg.isMine, isTrue);
    });

    test('parses pinned fields', () {
      final msg = ChatMessage.fromServerJson({
        'id': 'msg-1',
        'from_user_id': 'u1',
        'from_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
        'pinned_by_id': 'u2',
        'pinned_at': '2026-01-02T00:00:00Z',
      }, 'u1');
      expect(msg.pinnedById, 'u2');
      expect(msg.pinnedAt, isNotNull);
    });

    test('parses reactions list', () {
      final msg = ChatMessage.fromServerJson({
        'id': 'msg-1',
        'from_user_id': 'u1',
        'from_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
        'reactions': [
          {
            'message_id': 'msg-1',
            'user_id': 'u2',
            'username': 'bob',
            'emoji': '❤️',
          },
        ],
      }, 'u1');
      expect(msg.reactions, hasLength(1));
      expect(msg.reactions.first.emoji, '❤️');
    });

    test('trims empty channelId', () {
      final msg = ChatMessage.fromServerJson({
        'id': 'msg-1',
        'from_user_id': 'u1',
        'conversation_id': 'c1',
        'content': 'test',
        'channel_id': '  ',
      }, 'u1');
      expect(msg.channelId, isNull);
    });

    test('uses created_at as fallback for timestamp', () {
      final msg = ChatMessage.fromServerJson({
        'id': 'msg-1',
        'from_user_id': 'u1',
        'conversation_id': 'c1',
        'content': 'test',
        'created_at': '2026-06-01T00:00:00Z',
      }, 'u1');
      expect(msg.timestamp, '2026-06-01T00:00:00Z');
    });
  });

  group('ChatMessage.toJson', () {
    test('includes all fields', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        channelId: 'ch-1',
        content: 'Hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
        isEncrypted: true,
        editedAt: '2026-01-01T01:00:00Z',
        replyToId: 'msg-0',
        replyToContent: 'Original',
        replyToUsername: 'bob',
      );

      final json = msg.toJson();
      expect(json['message_id'], 'msg-1');
      expect(json['from_user_id'], 'user-1');
      expect(json['from_username'], 'alice');
      expect(json['conversation_id'], 'conv-1');
      expect(json['channel_id'], 'ch-1');
      expect(json['content'], 'Hello');
      expect(json['is_encrypted'], isTrue);
      expect(json['edited_at'], '2026-01-01T01:00:00Z');
      expect(json['reply_to_id'], 'msg-0');
      expect(json['reply_to_content'], 'Original');
      expect(json['reply_to_username'], 'bob');
    });
  });

  group('Conversation model', () {
    test('equality works correctly', () {
      const c1 = Conversation(id: 'c1', isGroup: false, unreadCount: 0);
      const c2 = Conversation(id: 'c1', isGroup: false, unreadCount: 0);
      const c3 = Conversation(id: 'c2', isGroup: true, unreadCount: 5);

      expect(c1, equals(c2));
      expect(c1, isNot(equals(c3)));
    });

    test('hashCode matches for equal objects', () {
      const c1 = Conversation(id: 'c1', isGroup: false);
      const c2 = Conversation(id: 'c1', isGroup: false);
      expect(c1.hashCode, equals(c2.hashCode));
    });

    test('copyWith updates all fields', () {
      const conv = Conversation(
        id: 'c1',
        name: 'Original',
        isGroup: false,
        unreadCount: 0,
      );

      final updated = conv.copyWith(
        name: 'Updated',
        description: 'A description',
        iconUrl: 'https://example.com/icon.png',
        isGroup: true,
        isEncrypted: true,
        lastMessage: 'Last msg',
        lastMessageTimestamp: '2026-01-01T00:00:00Z',
        lastMessageSender: 'alice',
        unreadCount: 5,
        isMuted: true,
      );

      expect(updated.id, 'c1'); // preserved
      expect(updated.name, 'Updated');
      expect(updated.description, 'A description');
      expect(updated.iconUrl, 'https://example.com/icon.png');
      expect(updated.isGroup, isTrue);
      expect(updated.isEncrypted, isTrue);
      expect(updated.lastMessage, 'Last msg');
      expect(updated.unreadCount, 5);
      expect(updated.isMuted, isTrue);
    });
  });

  group('Reaction model', () {
    test('fromJson parses all fields', () {
      final r = Reaction.fromJson({
        'message_id': 'msg-1',
        'user_id': 'user-1',
        'username': 'alice',
        'emoji': '🎉',
      });
      expect(r.messageId, 'msg-1');
      expect(r.userId, 'user-1');
      expect(r.username, 'alice');
      expect(r.emoji, '🎉');
    });

    test('toJson round-trips', () {
      const r = Reaction(
        messageId: 'msg-1',
        userId: 'user-1',
        username: 'alice',
        emoji: '👍',
      );
      final json = r.toJson();
      final restored = Reaction.fromJson(json);
      expect(restored.messageId, r.messageId);
      expect(restored.userId, r.userId);
      expect(restored.emoji, r.emoji);
    });
  });
}
