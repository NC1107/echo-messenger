import 'package:echo_app/src/widgets/input/input_status_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeTypingText', () {
    test('1:1 conversation always uses the peer display name', () {
      // typingUsers list is ignored for 1:1 — server only signals presence.
      expect(
        computeTypingText(
          typingUsers: ['Alice'],
          isGroup: false,
          displayName: 'Mira Chen',
        ),
        'Mira Chen is typing',
      );
    });

    test('group with empty typing list returns empty string', () {
      expect(
        computeTypingText(
          typingUsers: [],
          isGroup: true,
          displayName: 'echo-devs',
        ),
        '',
      );
    });

    test('group with 1 typer', () {
      expect(
        computeTypingText(
          typingUsers: ['Alice'],
          isGroup: true,
          displayName: 'echo-devs',
        ),
        'Alice is typing',
      );
    });

    test('group with 2 typers uses "and"', () {
      expect(
        computeTypingText(
          typingUsers: ['Alice', 'Bob'],
          isGroup: true,
          displayName: 'echo-devs',
        ),
        'Alice and Bob are typing',
      );
    });

    test('group with 3 typers shows two names + "1 other"', () {
      expect(
        computeTypingText(
          typingUsers: ['Alice', 'Bob', 'Carol'],
          isGroup: true,
          displayName: 'echo-devs',
        ),
        'Alice, Bob, and 1 other are typing',
      );
    });

    test('group with 5 typers pluralizes "others"', () {
      expect(
        computeTypingText(
          typingUsers: ['Alice', 'Bob', 'Carol', 'Dan', 'Erin'],
          isGroup: true,
          displayName: 'echo-devs',
        ),
        'Alice, Bob, and 3 others are typing',
      );
    });
  });
}
