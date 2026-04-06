import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketState;

void main() {
  group('WebSocketState', () {
    test('initial state is not connected', () {
      const state = WebSocketState();
      expect(state.isConnected, isFalse);
      expect(state.typingUsers, isEmpty);
      expect(state.onlineUsers, isEmpty);
    });

    test('copyWith sets isConnected to true', () {
      const state = WebSocketState();
      final connected = state.copyWith(isConnected: true);
      expect(connected.isConnected, isTrue);
    });

    test('copyWith preserves values when no arguments given', () {
      final state = WebSocketState(
        isConnected: true,
        onlineUsers: {'u1', 'u2'},
      );
      final copied = state.copyWith();
      expect(copied.isConnected, isTrue);
      expect(copied.onlineUsers, containsAll(['u1', 'u2']));
    });

    test('disconnect resets isConnected to false', () {
      const state = WebSocketState(isConnected: true);
      final disconnected = state.copyWith(isConnected: false);
      expect(disconnected.isConnected, isFalse);
    });

    test('isUserOnline returns true for online users', () {
      final state = WebSocketState(onlineUsers: {'user-1', 'user-2'});
      expect(state.isUserOnline('user-1'), isTrue);
      expect(state.isUserOnline('user-2'), isTrue);
      expect(state.isUserOnline('user-3'), isFalse);
    });

    test('typing indicators are tracked per conversation', () {
      final now = DateTime.now();
      final state = WebSocketState(
        typingUsers: {
          'conv-1:': {'alice': now},
          'conv-2:': {'bob': now},
        },
      );

      final typingInConv1 = state.typingIn('conv-1');
      expect(typingInConv1, contains('alice'));
      expect(typingInConv1, isNot(contains('bob')));

      final typingInConv2 = state.typingIn('conv-2');
      expect(typingInConv2, contains('bob'));
      expect(typingInConv2, isNot(contains('alice')));
    });

    test('stale typing indicators are filtered out', () {
      final staleTime = DateTime.now().subtract(const Duration(seconds: 10));
      final freshTime = DateTime.now();

      final state = WebSocketState(
        typingUsers: {
          'conv-1:': {'alice': staleTime, 'bob': freshTime},
        },
      );

      final typing = state.typingIn('conv-1');
      expect(typing, contains('bob'));
      expect(typing, isNot(contains('alice')));
    });

    test('typingIn with channelId uses composite key', () {
      final now = DateTime.now();
      final state = WebSocketState(
        typingUsers: {
          'conv-1:chan-1': {'alice': now},
          'conv-1:': {'bob': now},
        },
      );

      final typingInChannel = state.typingIn('conv-1', channelId: 'chan-1');
      expect(typingInChannel, contains('alice'));
      expect(typingInChannel, isNot(contains('bob')));

      final typingInGeneral = state.typingIn('conv-1');
      expect(typingInGeneral, contains('bob'));
      expect(typingInGeneral, isNot(contains('alice')));
    });

    test('typingIn returns empty list for unknown conversation', () {
      const state = WebSocketState();
      expect(state.typingIn('nonexistent'), isEmpty);
    });

    test('onlineUsers can be updated via copyWith', () {
      const state = WebSocketState();
      final withOnline = state.copyWith(onlineUsers: {'u1', 'u2', 'u3'});
      expect(withOnline.onlineUsers, hasLength(3));
      expect(withOnline.isUserOnline('u1'), isTrue);
      expect(withOnline.isUserOnline('u3'), isTrue);
    });

    test('onlineUsers empty set means no users online', () {
      final state = WebSocketState(onlineUsers: {'u1'});
      final cleared = state.copyWith(onlineUsers: <String>{});
      expect(cleared.onlineUsers, isEmpty);
      expect(cleared.isUserOnline('u1'), isFalse);
    });
  });
}
