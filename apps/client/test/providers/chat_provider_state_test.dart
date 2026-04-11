import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';

void main() {
  group('ChatState', () {
    test('default state has empty maps', () {
      const state = ChatState();
      expect(state.messagesByConversation, isEmpty);
      expect(state.loadingHistory, isEmpty);
      expect(state.hasMore, isEmpty);
      expect(state.replyToMessage, isNull);
    });

    test('messagesForConversation returns empty for unknown id', () {
      const state = ChatState();
      expect(state.messagesForConversation('unknown'), isEmpty);
    });

    test('messagesForConversation returns messages for known id', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final state = ChatState(
        messagesByConversation: {
          'conv-1': [msg],
        },
      );
      expect(state.messagesForConversation('conv-1'), hasLength(1));
      expect(state.messagesForConversation('conv-1').first.content, 'hello');
    });

    test('messagesForConversationChannel filters by channel', () {
      const msg1 = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        channelId: 'ch-1',
        content: 'in channel 1',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      const msg2 = ChatMessage(
        id: 'msg-2',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        channelId: 'ch-2',
        content: 'in channel 2',
        timestamp: '2026-01-01T00:01:00Z',
        isMine: false,
      );
      const msg3 = ChatMessage(
        id: 'msg-3',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'no channel',
        timestamp: '2026-01-01T00:02:00Z',
        isMine: false,
      );

      final state = ChatState(
        messagesByConversation: {
          'conv-1': [msg1, msg2, msg3],
        },
      );

      final ch1 = state.messagesForConversationChannel(
        'conv-1',
        channelId: 'ch-1',
      );
      expect(ch1, hasLength(1));
      expect(ch1.first.content, 'in channel 1');

      // With includeUnchanneled, should also include msg3
      final ch1WithUnchanneled = state.messagesForConversationChannel(
        'conv-1',
        channelId: 'ch-1',
        includeUnchanneled: true,
      );
      expect(ch1WithUnchanneled, hasLength(2));
    });

    test('isLoadingHistory returns correct value', () {
      final state = ChatState(loadingHistory: {'conv-1:': true});
      expect(state.isLoadingHistory('conv-1'), isTrue);
      expect(state.isLoadingHistory('conv-2'), isFalse);
    });

    test('isLoadingHistory with channel', () {
      final state = ChatState(loadingHistory: {'conv-1:ch-1': true});
      expect(state.isLoadingHistory('conv-1', channelId: 'ch-1'), isTrue);
      expect(state.isLoadingHistory('conv-1'), isFalse);
    });

    test('conversationHasMore defaults to true', () {
      const state = ChatState();
      expect(state.conversationHasMore('any'), isTrue);
    });

    test('conversationHasMore returns stored value', () {
      final state = ChatState(hasMore: {'conv-1:': false});
      expect(state.conversationHasMore('conv-1'), isFalse);
    });

    test('withMessage adds a new message', () {
      const state = ChatState();
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );

      final newState = state.withMessage(msg);
      expect(newState.messagesForConversation('conv-1'), hasLength(1));
    });

    test('withMessage deduplicates by ID', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );

      const state = ChatState();
      final state1 = state.withMessage(msg);
      final state2 = state1.withMessage(msg);
      expect(state2.messagesForConversation('conv-1'), hasLength(1));
    });

    test('copyWith preserves unchanged fields', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final state = ChatState(
        messagesByConversation: {
          'conv-1': [msg],
        },
      );

      final copied = state.copyWith(loadingHistory: {'conv-1:': true});
      expect(copied.messagesForConversation('conv-1'), hasLength(1));
      expect(copied.isLoadingHistory('conv-1'), isTrue);
    });

    test('copyWith with clearReply sets replyToMessage to null', () {
      const reply = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'reply target',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      const state = ChatState(replyToMessage: reply);

      final cleared = state.copyWith(clearReply: true);
      expect(cleared.replyToMessage, isNull);
    });

    test('copyWith sets replyToMessage', () {
      const reply = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'reply target',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      const state = ChatState();

      final withReply = state.copyWith(replyToMessage: reply);
      expect(withReply.replyToMessage, isNotNull);
      expect(withReply.replyToMessage!.content, 'reply target');
    });
  });

  group('ChatMessage', () {
    test('fromServerJson parses all fields', () {
      final msg = ChatMessage.fromServerJson({
        'message_id': 'msg-1',
        'from_user_id': 'user-1',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': 'Hello world',
        'timestamp': '2026-01-01T00:00:00Z',
        'edited_at': '2026-01-01T01:00:00Z',
        'reply_to_id': 'msg-0',
        'reply_to_content': 'Original message',
        'reply_to_username': 'bob',
      }, 'user-1');

      expect(msg.id, 'msg-1');
      expect(msg.fromUserId, 'user-1');
      expect(msg.fromUsername, 'alice');
      expect(msg.conversationId, 'conv-1');
      expect(msg.content, 'Hello world');
      expect(msg.isMine, isTrue);
      expect(msg.editedAt, '2026-01-01T01:00:00Z');
      expect(msg.replyToId, 'msg-0');
      expect(msg.replyToContent, 'Original message');
      expect(msg.replyToUsername, 'bob');
    });

    test('fromServerJson handles missing fields', () {
      final msg = ChatMessage.fromServerJson({}, 'me');
      expect(msg.id, '');
      expect(msg.fromUserId, '');
      expect(msg.content, '');
      expect(msg.isMine, isFalse);
    });

    test('toJson round-trips with fromServerJson', () {
      const original = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'test',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: true,
        isEncrypted: true,
      );

      final json = original.toJson();
      final restored = ChatMessage.fromServerJson(json, 'user-1');

      expect(restored.id, original.id);
      expect(restored.fromUserId, original.fromUserId);
      expect(restored.content, original.content);
      expect(restored.conversationId, original.conversationId);
      expect(restored.isMine, isTrue);
    });

    test('isSystemEvent returns true for system messages', () {
      const msg = ChatMessage(
        id: 'sys-1',
        fromUserId: '__system__',
        fromUsername: 'System',
        conversationId: 'conv-1',
        content: 'User joined',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      expect(msg.isSystemEvent, isTrue);
    });

    test('isSystemEvent returns false for normal messages', () {
      const msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'user-1',
        fromUsername: 'alice',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      expect(msg.isSystemEvent, isFalse);
    });

    test('MessageStatus enum has all expected values', () {
      expect(
        MessageStatus.values,
        containsAll([
          MessageStatus.sending,
          MessageStatus.sent,
          MessageStatus.delivered,
          MessageStatus.read,
          MessageStatus.failed,
        ]),
      );
    });
  });

  group('ConversationsState', () {
    test('default state is empty', () {
      const state = ConversationsState();
      expect(state.conversations, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      const state = ConversationsState(isLoading: true);
      final copied = state.copyWith(error: 'failed');
      expect(copied.isLoading, isTrue);
      expect(copied.error, 'failed');
    });
  });
}
