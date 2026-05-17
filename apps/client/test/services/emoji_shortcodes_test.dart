import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/services/emoji_shortcodes.dart';

void main() {
  group('expandEmojiShortcodes', () {
    test('expands single shortcode', () {
      expect(expandEmojiShortcodes(':smile:'), '😄');
    });

    test('expands multiple shortcodes', () {
      expect(
        expandEmojiShortcodes(':smile: and :heart: and :fire:'),
        '😄 and ❤️ and 🔥',
      );
    });

    test('leaves unknown shortcodes unchanged', () {
      expect(expandEmojiShortcodes(':unknown_emoji:'), ':unknown_emoji:');
    });

    test('mixes known and unknown shortcodes', () {
      expect(expandEmojiShortcodes(':smile: :unknown:'), '😄 :unknown:');
    });

    test('preserves plain text without shortcodes', () {
      expect(expandEmojiShortcodes('Hello world'), 'Hello world');
    });

    test('expands thumbsup and thumbsdown variants', () {
      expect(expandEmojiShortcodes(':+1:'), '👍');
      expect(expandEmojiShortcodes(':-1:'), '👎');
    });

    test('handles empty string', () {
      expect(expandEmojiShortcodes(''), '');
    });

    test('handles shortcodes at message start and end', () {
      expect(expandEmojiShortcodes(':tada: hello :rocket:'), '🎉 hello 🚀');
    });
  });
}
