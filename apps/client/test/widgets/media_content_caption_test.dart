// Unit tests for marker + caption parsing in media_content.dart (#795).
// Messages of the form `[img:URL]\nCaption` must extract the URL and the
// caption separately so the renderer can show both inline media and the
// caption text underneath.
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/media_content.dart';

void main() {
  group('extractMediaUrl with caption (#795)', () {
    test('returns URL when content is a bare [img:] marker', () {
      expect(extractMediaUrl('[img:/api/media/abc-123]'), '/api/media/abc-123');
    });

    test('returns URL when [img:] marker is followed by a caption', () {
      expect(
        extractMediaUrl('[img:/api/media/abc-123]\nLook at this'),
        '/api/media/abc-123',
      );
    });

    test('returns URL for [video:] marker with caption', () {
      expect(
        extractMediaUrl('[video:/api/media/v]\nClip from yesterday'),
        '/api/media/v',
      );
    });

    test('returns URL for [file:] marker with caption', () {
      expect(
        extractMediaUrl('[file:/api/media/f]\nslides.pdf'),
        '/api/media/f',
      );
    });

    test('returns URL for [audio:] marker with caption', () {
      expect(
        extractMediaUrl('[audio:/api/media/a]\nvoice memo'),
        '/api/media/a',
      );
    });

    test('returns null for plain text', () {
      expect(extractMediaUrl('hello world'), isNull);
    });
  });

  group('extractMediaCaption (#795)', () {
    test('returns null when there is no caption', () {
      expect(extractMediaCaption('[img:/api/media/x]'), isNull);
    });

    test('returns caption text after a marker', () {
      expect(extractMediaCaption('[img:/x]\nLook'), 'Look');
    });

    test('trims whitespace around the caption', () {
      expect(extractMediaCaption('[img:/x]\n  Hello  '), 'Hello');
    });

    test('returns null when content is plain text', () {
      expect(extractMediaCaption('just a sentence'), isNull);
    });

    test('handles each marker type', () {
      expect(extractMediaCaption('[video:/v]\ncap'), 'cap');
      expect(extractMediaCaption('[file:/f]\ncap'), 'cap');
      expect(extractMediaCaption('[audio:/a]\ncap'), 'cap');
    });
  });
}
