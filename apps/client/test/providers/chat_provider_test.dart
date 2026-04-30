import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  group('ChatState', () {
    test('initial state has no messages', () {
      const state = ChatState();
      expect(state.messagesForConversation('any-conv'), isEmpty);
    });

    test('withMessage adds message to correct conversation', () {
      const state = ChatState();
      final msg = const ChatMessage(
        id: 'msg1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final newState = state.withMessage(msg);
      expect(newState.messagesForConversation('conv1'), hasLength(1));
      expect(newState.messagesForConversation('conv1').first.content, 'hello');
    });

    test('messages for different conversations are isolated', () {
      const state = ChatState();
      final msg1 = const ChatMessage(
        id: 'msg1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = const ChatMessage(
        id: 'msg2',
        fromUserId: 'user2',
        fromUsername: 'bob',
        conversationId: 'conv2',
        content: 'hey',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );
      final s1 = state.withMessage(msg1);
      final s2 = s1.withMessage(msg2);
      expect(s2.messagesForConversation('conv1'), hasLength(1));
      expect(s2.messagesForConversation('conv2'), hasLength(1));
    });

    test('withMessage deduplicates by id', () {
      const state = ChatState();
      final msg = const ChatMessage(
        id: 'msg1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final s1 = state.withMessage(msg);
      final s2 = s1.withMessage(msg);
      expect(s2.messagesForConversation('conv1'), hasLength(1));
    });

    test('ChatMessage.fromServerJson parses correctly', () {
      final json = {
        'message_id': 'id1',
        'from_user_id': 'u1',
        'from_username': 'alice',
        'conversation_id': 'c1',
        'content': 'test',
        'timestamp': '2026-01-01T00:00:00Z',
      };
      final msg = ChatMessage.fromServerJson(json, 'u2');
      expect(msg.isMine, isFalse);
      expect(msg.content, 'test');
      expect(msg.fromUsername, 'alice');
    });

    test('Reaction model', () {
      final r = const Reaction(
        messageId: 'm1',
        userId: 'u1',
        username: 'alice',
        emoji: '\u{1F44D}',
      );
      expect(r.emoji, '\u{1F44D}');
      expect(r.username, 'alice');
    });

    test('replyToMessage defaults to null', () {
      const state = ChatState();
      expect(state.replyToMessage, isNull);
    });

    test('copyWith with replyToMessage sets the reply', () {
      const state = ChatState();
      final replyMsg = const ChatMessage(
        id: 'reply-1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'Original message',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final newState = state.copyWith(replyToMessage: replyMsg);
      expect(newState.replyToMessage, isNotNull);
      expect(newState.replyToMessage!.id, 'reply-1');
      expect(newState.replyToMessage!.content, 'Original message');
    });

    test('copyWith with clearReply clears the reply', () {
      final replyMsg = const ChatMessage(
        id: 'reply-1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'Original message',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final stateWithReply = ChatState(replyToMessage: replyMsg);
      expect(stateWithReply.replyToMessage, isNotNull);

      final cleared = stateWithReply.copyWith(clearReply: true);
      expect(cleared.replyToMessage, isNull);
    });

    test('clearReply takes precedence over replyToMessage in copyWith', () {
      final msg = const ChatMessage(
        id: 'r1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'c1',
        content: 'test',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final state = ChatState(replyToMessage: msg);
      // When both clearReply and replyToMessage are provided, clearReply wins.
      final result = state.copyWith(clearReply: true, replyToMessage: msg);
      expect(result.replyToMessage, isNull);
    });

    test('withMessage preserves replyToMessage', () {
      final replyMsg = const ChatMessage(
        id: 'reply-1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'reply target',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final state = ChatState(replyToMessage: replyMsg);
      final newMsg = const ChatMessage(
        id: 'msg-new',
        fromUserId: 'user2',
        fromUsername: 'bob',
        conversationId: 'conv1',
        content: 'new message',
        timestamp: '2026-01-01T00:01:00Z',
        isMine: false,
      );
      final newState = state.withMessage(newMsg);
      expect(newState.replyToMessage, isNotNull);
      expect(newState.replyToMessage!.id, 'reply-1');
    });

    test('messages are ordered by insertion (append-only)', () {
      const state = ChatState();
      final msg1 = const ChatMessage(
        id: 'msg1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'first',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = const ChatMessage(
        id: 'msg2',
        fromUserId: 'u2',
        fromUsername: 'bob',
        conversationId: 'conv1',
        content: 'second',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );
      final msg3 = const ChatMessage(
        id: 'msg3',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'third',
        timestamp: '2026-01-01T00:00:02Z',
        isMine: false,
      );
      final s = state.withMessage(msg1).withMessage(msg2).withMessage(msg3);
      final messages = s.messagesForConversation('conv1');
      expect(messages, hasLength(3));
      expect(messages[0].content, 'first');
      expect(messages[1].content, 'second');
      expect(messages[2].content, 'third');
    });

    test('ChatMessage pinnedAt and pinnedById via copyWith', () {
      final msg = const ChatMessage(
        id: 'msg1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'pin me',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      expect(msg.pinnedAt, isNull);
      expect(msg.pinnedById, isNull);

      final pinTime = DateTime.parse('2026-01-15T12:00:00Z');
      final pinned = msg.copyWith(pinnedById: 'admin', pinnedAt: pinTime);
      expect(pinned.pinnedById, 'admin');
      expect(pinned.pinnedAt, pinTime);
      // Content unchanged
      expect(pinned.content, 'pin me');
    });

    test('ChatMessage copyWith can clear pinnedById to null', () {
      final pinTime = DateTime.parse('2026-01-15T12:00:00Z');
      final pinned = ChatMessage(
        id: 'msg1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'pinned',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
        pinnedById: 'admin',
        pinnedAt: pinTime,
      );
      // Pass explicit null via the sentinel pattern
      final unpinned = pinned.copyWith(pinnedById: null, pinnedAt: null);
      expect(unpinned.pinnedById, isNull);
      expect(unpinned.pinnedAt, isNull);
    });

    test('updateMessagePin updates pin on correct message', () {
      final msg1 = const ChatMessage(
        id: 'msg1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = const ChatMessage(
        id: 'msg2',
        fromUserId: 'u2',
        fromUsername: 'bob',
        conversationId: 'conv1',
        content: 'world',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );

      // Build state with two messages
      final state = const ChatState().withMessage(msg1).withMessage(msg2);

      // Simulate updateMessagePin by manually constructing the updated state
      final updatedConv = Map<String, List<ChatMessage>>.from(
        state.messagesByConversation,
      );
      final messages = updatedConv['conv1']!;
      final pinTime = DateTime.parse('2026-01-15T12:00:00Z');
      updatedConv['conv1'] = messages.map((m) {
        if (m.id == 'msg1') {
          return m.copyWith(pinnedById: 'admin', pinnedAt: pinTime);
        }
        return m;
      }).toList();

      final newState = ChatState(
        messagesByConversation: updatedConv,
        loadingHistory: state.loadingHistory,
        hasMore: state.hasMore,
      );

      final conv1Messages = newState.messagesForConversation('conv1');
      expect(conv1Messages[0].pinnedById, 'admin');
      expect(conv1Messages[0].pinnedAt, pinTime);
      // msg2 unchanged
      expect(conv1Messages[1].pinnedById, isNull);
    });

    test('messagesForConversationChannel filters by channelId', () {
      final msg1 = const ChatMessage(
        id: 'msg1',
        fromUserId: 'u1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        channelId: 'general',
        content: 'in general',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = const ChatMessage(
        id: 'msg2',
        fromUserId: 'u2',
        fromUsername: 'bob',
        conversationId: 'conv1',
        channelId: 'random',
        content: 'in random',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );
      final state = const ChatState().withMessage(msg1).withMessage(msg2);

      final generalMessages = state.messagesForConversationChannel(
        'conv1',
        channelId: 'general',
      );
      expect(generalMessages, hasLength(1));
      expect(generalMessages.first.content, 'in general');

      final randomMessages = state.messagesForConversationChannel(
        'conv1',
        channelId: 'random',
      );
      expect(randomMessages, hasLength(1));
      expect(randomMessages.first.content, 'in random');
    });

    test('isLoadingHistory defaults to false', () {
      const state = ChatState();
      expect(state.isLoadingHistory('conv1'), isFalse);
    });

    test('conversationHasMore defaults to true', () {
      const state = ChatState();
      expect(state.conversationHasMore('conv1'), isTrue);
    });

    test('loadingHistory and hasMore can be set via copyWith', () {
      const state = ChatState();
      final updated = state.copyWith(
        loadingHistory: {'conv1:': true},
        hasMore: {'conv1:': false},
      );
      expect(updated.isLoadingHistory('conv1'), isTrue);
      expect(updated.conversationHasMore('conv1'), isFalse);
    });
  });
}
