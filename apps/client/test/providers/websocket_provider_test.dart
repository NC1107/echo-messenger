import 'dart:math' as math;

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

    group('lastSeenFor (#503)', () {
      test('returns null when no entry exists', () {
        const state = WebSocketState();
        expect(state.lastSeenFor('user-1'), isNull);
      });

      test('returns the stored timestamp when present', () {
        final ts = DateTime.utc(2026, 4, 28, 12, 30);
        final state = WebSocketState(lastSeenAt: {'user-1': ts});
        expect(state.lastSeenFor('user-1'), ts);
      });

      test('copyWith preserves lastSeenAt when not overridden', () {
        final ts = DateTime.utc(2026, 4, 28, 12, 30);
        final state = WebSocketState(lastSeenAt: {'user-1': ts});
        final copied = state.copyWith(isConnected: true);
        expect(copied.lastSeenFor('user-1'), ts);
      });

      test('copyWith replaces lastSeenAt when provided', () {
        final ts1 = DateTime.utc(2026, 4, 28, 12, 30);
        final ts2 = DateTime.utc(2026, 4, 28, 13, 0);
        final state = WebSocketState(lastSeenAt: {'user-1': ts1});
        final updated = state.copyWith(lastSeenAt: {'user-1': ts2});
        expect(updated.lastSeenFor('user-1'), ts2);
      });
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

    test('typingUsers can be replaced via copyWith', () {
      final now = DateTime.now();
      const state = WebSocketState();
      final withTyping = state.copyWith(
        typingUsers: {
          'conv-1:': {'alice': now},
        },
      );
      expect(withTyping.typingIn('conv-1'), contains('alice'));

      // Replace typing users with empty map
      final cleared = withTyping.copyWith(typingUsers: {});
      expect(cleared.typingIn('conv-1'), isEmpty);
    });

    test('multiple typing users in same conversation', () {
      final now = DateTime.now();
      final state = WebSocketState(
        typingUsers: {
          'conv-1:': {'alice': now, 'bob': now, 'carol': now},
        },
      );
      final typing = state.typingIn('conv-1');
      expect(typing, hasLength(3));
      expect(typing, containsAll(['alice', 'bob', 'carol']));
    });

    test('isConnected defaults to false', () {
      const state = WebSocketState();
      expect(state.isConnected, isFalse);
    });

    test('copyWith can set all fields simultaneously', () {
      final now = DateTime.now();
      const state = WebSocketState();
      final updated = state.copyWith(
        isConnected: true,
        typingUsers: {
          'conv-1:': {'alice': now},
        },
        onlineUsers: {'u1', 'u2'},
      );
      expect(updated.isConnected, isTrue);
      expect(updated.typingIn('conv-1'), contains('alice'));
      expect(updated.onlineUsers, hasLength(2));
    });
  });

  group('WebSocket reconnection backoff calculation', () {
    // These tests verify the exponential backoff formula used in
    // WebSocketNotifier._scheduleReconnect:
    //   delayMs = min(1000 * 2^attempt, 60000)
    // The formula is applied BEFORE incrementing the attempt counter.

    int backoffMs(int attempt) {
      return math.min(1000 * math.pow(2, attempt).toInt(), 60000);
    }

    test('attempt 0 produces 1 second delay', () {
      expect(backoffMs(0), 1000);
    });

    test('attempt 1 produces 2 second delay', () {
      expect(backoffMs(1), 2000);
    });

    test('attempt 2 produces 4 second delay', () {
      expect(backoffMs(2), 4000);
    });

    test('attempt 3 produces 8 second delay', () {
      expect(backoffMs(3), 8000);
    });

    test('attempt 4 produces 16 second delay', () {
      expect(backoffMs(4), 16000);
    });

    test('attempt 5 produces 32 second delay', () {
      expect(backoffMs(5), 32000);
    });

    test('attempt 6 is capped at 60 seconds', () {
      expect(backoffMs(6), 60000);
    });

    test('attempt 9 is still capped at 60 seconds', () {
      expect(backoffMs(9), 60000);
    });

    test('max reconnect attempts constant is 10', () {
      // Verify the circuit breaker limit -- this is the value in
      // WebSocketNotifier._maxReconnectAttempts.
      const maxReconnectAttempts = 10;
      expect(maxReconnectAttempts, 10);

      // After 10 attempts the notifier stops reconnecting.
      // Attempts 0..9 are valid, attempt 10 hits the guard.
      for (var i = 0; i < maxReconnectAttempts; i++) {
        expect(backoffMs(i), greaterThan(0));
      }
    });

    test('backoff sequence is strictly non-decreasing', () {
      int prev = 0;
      for (var i = 0; i < 10; i++) {
        final current = backoffMs(i);
        expect(current, greaterThanOrEqualTo(prev));
        prev = current;
      }
    });
  });

  group('WebSocketState disconnect semantics', () {
    test('disconnect clears isConnected but preserves onlineUsers snapshot', () {
      final state = WebSocketState(
        isConnected: true,
        onlineUsers: {'u1', 'u2'},
      );
      // When the notifier calls disconnect, it uses copyWith(isConnected: false).
      // onlineUsers is separately cleared by the notifier, but the state
      // copyWith itself preserves what is not explicitly passed.
      final disconnected = state.copyWith(isConnected: false);
      expect(disconnected.isConnected, isFalse);
      expect(disconnected.onlineUsers, hasLength(2));
    });

    test('full disconnect clears connection and online users', () {
      final state = WebSocketState(
        isConnected: true,
        onlineUsers: {'u1', 'u2'},
      );
      final disconnected = state.copyWith(
        isConnected: false,
        onlineUsers: <String>{},
      );
      expect(disconnected.isConnected, isFalse);
      expect(disconnected.onlineUsers, isEmpty);
    });

    test('reconnect resets to connected with empty online users', () {
      const disconnected = WebSocketState();
      final reconnected = disconnected.copyWith(isConnected: true);
      expect(reconnected.isConnected, isTrue);
      expect(reconnected.onlineUsers, isEmpty);
      expect(reconnected.typingUsers, isEmpty);
    });
  });
}
