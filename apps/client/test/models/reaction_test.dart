import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  group('Reaction', () {
    test('fromJson parses correctly', () {
      final json = {
        'message_id': 'msg-1',
        'user_id': 'user-abc',
        'username': 'alice',
        'emoji': '👍',
      };

      final reaction = Reaction.fromJson(json);

      expect(reaction.messageId, 'msg-1');
      expect(reaction.userId, 'user-abc');
      expect(reaction.username, 'alice');
      expect(reaction.emoji, '👍');
    });

    test('toJson serializes correctly', () {
      const reaction = Reaction(
        messageId: 'msg-1',
        userId: 'user-abc',
        username: 'alice',
        emoji: '❤️',
      );

      final json = reaction.toJson();

      expect(json['message_id'], 'msg-1');
      expect(json['user_id'], 'user-abc');
      expect(json['username'], 'alice');
      expect(json['emoji'], '❤️');
    });

    test('equality works correctly', () {
      const r1 = Reaction(
        messageId: 'msg-1',
        userId: 'user-1',
        username: 'alice',
        emoji: '👍',
      );
      const r2 = Reaction(
        messageId: 'msg-1',
        userId: 'user-1',
        username: 'alice',
        emoji: '👍',
      );
      const r3 = Reaction(
        messageId: 'msg-1',
        userId: 'user-2',
        username: 'bob',
        emoji: '👍',
      );

      expect(r1, equals(r2));
      expect(r1, isNot(equals(r3)));
    });
  });
}
