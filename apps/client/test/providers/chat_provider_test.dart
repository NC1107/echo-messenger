import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/models/chat_message.dart';

void main() {
  late ChatNotifier notifier;

  setUp(() {
    notifier = ChatNotifier();
  });

  group('ChatNotifier', () {
    test('initial state has no messages', () {
      expect(notifier.state.messagesFor('any-peer'), isEmpty);
      expect(notifier.state.messagesByPeer, isEmpty);
    });

    test('addMessage stores message retrievable by peer', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      notifier.addMessage(msg);

      final messages = notifier.state.messagesFor('peer-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, 'hello');
    });

    test('addOptimistic adds message for peer', () {
      notifier.addOptimistic('peer-1', 'optimistic msg', 'my-user-id');

      final messages = notifier.state.messagesFor('peer-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, 'optimistic msg');
      expect(messages.first.isMine, isTrue);
      expect(messages.first.id, startsWith('pending_'));
    });

    test('messages for different peers are isolated', () {
      final msg1 = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-a',
        fromUsername: 'A',
        conversationId: 'conv-1',
        content: 'from A',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );
      final msg2 = ChatMessage(
        id: 'msg-2',
        fromUserId: 'peer-b',
        fromUsername: 'B',
        conversationId: 'conv-2',
        content: 'from B',
        timestamp: '2026-03-31T12:01:00Z',
        isMine: false,
      );

      notifier.addMessage(msg1);
      notifier.addMessage(msg2);

      expect(notifier.state.messagesFor('peer-a'), hasLength(1));
      expect(notifier.state.messagesFor('peer-b'), hasLength(1));
      expect(notifier.state.messagesFor('peer-a').first.content, 'from A');
      expect(notifier.state.messagesFor('peer-b').first.content, 'from B');
    });

    test('clear removes all messages', () {
      notifier.addOptimistic('peer-1', 'msg', 'my-id');
      expect(notifier.state.messagesFor('peer-1'), isNotEmpty);

      notifier.clear();

      expect(notifier.state.messagesFor('peer-1'), isEmpty);
      expect(notifier.state.messagesByPeer, isEmpty);
    });
  });
}
