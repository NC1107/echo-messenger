import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/mention_detection.dart';

void main() {
  group('containsMention', () {
    test('matches @username at start', () {
      expect(containsMention('@dev hi', 'dev'), isTrue);
    });

    test('matches @username after whitespace', () {
      expect(containsMention('hello @dev', 'dev'), isTrue);
    });

    test('matches @username after punctuation', () {
      expect(containsMention('great work, @dev!', 'dev'), isTrue);
    });

    test('does not match email-like x@username', () {
      expect(containsMention('me@dev', 'dev'), isFalse);
    });

    test('does not match longer-word @usernameish', () {
      expect(containsMention('@develop', 'dev'), isFalse);
    });

    test('matches @everyone broadcast', () {
      expect(containsMention('@everyone heads up', null), isTrue);
      expect(containsMention('@everyone heads up', 'someone'), isTrue);
    });

    test('matches @here broadcast', () {
      expect(containsMention('@here?', null), isTrue);
    });

    test('rejects @hereafter', () {
      expect(containsMention('@hereafter we go', null), isFalse);
    });

    test('rejects @everyones', () {
      expect(containsMention('@everyones birthday', null), isFalse);
    });

    test('case-insensitive on username', () {
      expect(containsMention('@Dev hi', 'dev'), isTrue);
      expect(containsMention('@DEV hi', 'dev'), isTrue);
      expect(containsMention('@dev hi', 'DEV'), isTrue);
    });

    test('case-insensitive on broadcast keywords', () {
      expect(containsMention('Yo @Here folks', null), isTrue);
      expect(containsMention('YO @EVERYONE FOLKS', null), isTrue);
    });

    test('empty content returns false', () {
      expect(containsMention('', 'dev'), isFalse);
    });

    test('null/empty username only matches broadcasts', () {
      expect(containsMention('@dev', null), isFalse);
      expect(containsMention('@dev', ''), isFalse);
      expect(containsMention('@here', null), isTrue);
    });

    test('username with underscore boundary rejected', () {
      // `@dev_lounge` is a different identifier; do not fire on @dev.
      expect(containsMention('@dev_lounge', 'dev'), isFalse);
    });

    test('multiple mentions still detected', () {
      expect(containsMention('hi @alice and @dev', 'dev'), isTrue);
    });

    test('content with @ but no real mention returns false', () {
      expect(containsMention('email me at user@example.com', 'dev'), isFalse);
    });
  });

  group('containsKeywordMention (exposed for tests)', () {
    test('matches lone keyword', () {
      expect(containsKeywordMention('@everyone', 'everyone'), isTrue);
    });

    test('rejects empty keyword', () {
      expect(containsKeywordMention('@here', ''), isFalse);
    });
  });
}
