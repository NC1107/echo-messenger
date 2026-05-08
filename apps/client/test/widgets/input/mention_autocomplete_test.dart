import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/input/mention_controller.dart';

void main() {
  group('extractMentionQuery', () {
    test('returns null when no @ in text', () {
      expect(extractMentionQuery('hello world', 11), isNull);
    });

    test('returns null when cursor is out of range', () {
      expect(extractMentionQuery('@al', -1), isNull);
      expect(extractMentionQuery('@al', 99), isNull);
    });

    test('returns query when @ at start of string', () {
      expect(extractMentionQuery('@al', 3), 'al');
    });

    test('returns lowercased query', () {
      expect(extractMentionQuery('@AlICe', 6), 'alice');
    });

    test('returns query when @ follows a space', () {
      expect(extractMentionQuery('hi @bo', 6), 'bo');
    });

    test('returns null when @ is mid-word (no leading space)', () {
      // e.g. an email address
      expect(extractMentionQuery('me@host', 7), isNull);
    });

    test('returns null when query contains a space (mention closed)', () {
      expect(extractMentionQuery('@alice was here', 15), isNull);
    });

    test('cursor before the @ does not extract', () {
      // cursor sits BEFORE the @, so beforeCursor has no @
      expect(extractMentionQuery('hi @bo', 2), isNull);
    });

    test('returns empty string when only @ has been typed', () {
      expect(extractMentionQuery('@', 1), '');
    });

    test('works for broadcast keywords (everyone / here)', () {
      expect(extractMentionQuery('@every', 6), 'every');
      expect(extractMentionQuery('hi @here', 8), 'here');
    });

    test('accepts tab as left boundary', () {
      expect(extractMentionQuery('\t@al', 4), 'al');
    });

    test('accepts newline as left boundary', () {
      expect(extractMentionQuery('first\n@al', 9), 'al');
    });

    test('breaks on tab inside the partial', () {
      expect(extractMentionQuery('@al\tice', 7), isNull);
    });
  });

  group('insertMention', () {
    test('replaces partial query with username and trailing space', () {
      const text = '@al';
      final result = insertMention(
        text: text,
        cursorPosition: 3,
        username: 'alice',
      );
      expect(result.text, '@alice ');
      expect(result.selection.baseOffset, '@alice '.length);
    });

    test('preserves text before and after the partial', () {
      const text = 'hey @bo more';
      final result = insertMention(
        text: text,
        cursorPosition: 7, // right after "@bo"
        username: 'bob',
      );
      expect(result.text, 'hey @bob  more');
      // Cursor sits right after the inserted "@bob "
      expect(result.selection.baseOffset, 'hey @bob '.length);
    });

    test('inserts everyone keyword', () {
      const text = '@every';
      final result = insertMention(
        text: text,
        cursorPosition: 6,
        username: 'everyone',
      );
      expect(result.text, '@everyone ');
    });

    test('returns original text when no @ was found', () {
      const text = 'hello';
      final result = insertMention(
        text: text,
        cursorPosition: 5,
        username: 'alice',
      );
      expect(result.text, 'hello');
      // No selection set (defaulted) — just confirm no crash and text unchanged.
    });

    test('returns original text on negative cursor', () {
      final result = insertMention(
        text: '@al',
        cursorPosition: -1,
        username: 'alice',
      );
      expect(result.text, '@al');
    });

    test('result selection is collapsed', () {
      final result = insertMention(
        text: '@al',
        cursorPosition: 3,
        username: 'alice',
      );
      expect(result.selection, isA<TextSelection>());
      expect(result.selection.isCollapsed, isTrue);
    });
  });
}
