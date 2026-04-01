import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  group('ChatState', () {
    test('initial state has no messages', () {
      const state = ChatState();
      expect(state.messagesFor('any-peer'), isEmpty);
      expect(state.messagesForConversation('any-conv'), isEmpty);
    });

    test('withMessage adds message to correct peer', () {
      const state = ChatState();
      final msg = ChatMessage(
        id: 'msg1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final newState = state.withMessage('user1', msg);
      expect(newState.messagesFor('user1'), hasLength(1));
      expect(newState.messagesFor('user1').first.content, 'hello');
    });

    test('messages for different peers are isolated', () {
      const state = ChatState();
      final msg1 = ChatMessage(
        id: 'msg1',
        fromUserId: 'user1',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = ChatMessage(
        id: 'msg2',
        fromUserId: 'user2',
        fromUsername: 'bob',
        conversationId: 'conv2',
        content: 'hey',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );
      final s1 = state.withMessage('user1', msg1);
      final s2 = s1.withMessage('user2', msg2);
      expect(s2.messagesFor('user1'), hasLength(1));
      expect(s2.messagesFor('user2'), hasLength(1));
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
      final r = Reaction(
        messageId: 'm1',
        userId: 'u1',
        username: 'alice',
        emoji: '👍',
      );
      expect(r.emoji, '👍');
      expect(r.username, 'alice');
    });
  });
}
