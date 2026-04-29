import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/semantics_preview.dart';

void main() {
  group('previewForSemantics', () {
    test('returns plaintext unchanged when short and tag-free', () {
      expect(previewForSemantics('hello world'), 'hello world');
    });

    test('returns empty string for empty input', () {
      expect(previewForSemantics(''), '');
    });

    test('substitutes [img:...] with "Image"', () {
      expect(previewForSemantics('[img:cat.jpg]'), 'Image');
      expect(
        previewForSemantics('look at this [img:cat.jpg] cute cat'),
        'look at this Image cute cat',
      );
    });

    test('substitutes [file:...] with "File"', () {
      expect(previewForSemantics('[file:notes.pdf]'), 'File');
    });

    test('substitutes [voice:...] with "Voice message"', () {
      expect(previewForSemantics('[voice:msg-1]'), 'Voice message');
    });

    test('substitutes [video:...] with "Video"', () {
      // Video is an active wire format -- review surfaced that omitting
      // the substitution would leave the screen reader silent on a
      // video-only message.
      expect(previewForSemantics('[video:clip.mp4]'), 'Video');
    });

    test('strips unknown bracketed tokens', () {
      expect(
        previewForSemantics('start [unknown:x] middle [thing:y] end'),
        'start middle end',
      );
    });

    test('collapses whitespace runs', () {
      expect(previewForSemantics('a   b\t\tc\n\nd'), 'a b c d');
    });

    test('returns 79-char input unchanged (under truncation boundary)', () {
      final input = 'x' * 79;
      expect(previewForSemantics(input), input);
    });

    test('returns 80-char input unchanged (at truncation boundary)', () {
      final input = 'x' * 80;
      expect(previewForSemantics(input), input);
    });

    test('truncates 81-char input with ellipsis', () {
      final input = 'x' * 81;
      final result = previewForSemantics(input);
      expect(result.length, 81); // 80 chars + 1 ellipsis codepoint
      expect(result.endsWith('…'), isTrue);
    });

    test('truncation runs after substitution + whitespace collapse', () {
      // [img:...] expands to "Image" (5 chars) which counts toward the budget.
      final input = '${'a' * 70} [img:big.png] ${'b' * 30}';
      final result = previewForSemantics(input);
      // Substituted, whitespace-collapsed, then truncated.
      expect(result.endsWith('…'), isTrue);
      expect(result.length, 81);
      expect(result.startsWith('a'), isTrue);
    });
  });
}
