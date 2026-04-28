import 'package:echo_app/src/widgets/message/youtube_embed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YouTubeEmbed.extractId', () {
    test('matches youtube.com/watch URLs', () {
      expect(
        YouTubeEmbed.extractId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('matches youtu.be short URLs', () {
      expect(
        YouTubeEmbed.extractId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('matches mobile watch URLs', () {
      expect(
        YouTubeEmbed.extractId('https://m.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('matches shorts URLs', () {
      expect(
        YouTubeEmbed.extractId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('matches embed URLs', () {
      expect(
        YouTubeEmbed.extractId('https://www.youtube.com/embed/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('returns null for non-YouTube URLs', () {
      expect(
        YouTubeEmbed.extractId('https://example.com/watch?v=dQw4w9WgXcQ'),
        isNull,
      );
      expect(YouTubeEmbed.extractId('https://vimeo.com/12345'), isNull);
      expect(YouTubeEmbed.extractId(''), isNull);
    });

    test('returns null when video id is wrong length', () {
      // 10 chars instead of the required 11
      expect(YouTubeEmbed.extractId('https://youtu.be/abc1234567'), isNull);
    });

    test('rejects URLs that look right but have extra leading text', () {
      expect(
        YouTubeEmbed.extractId(
          'see also https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isNull,
      );
    });
  });
}
