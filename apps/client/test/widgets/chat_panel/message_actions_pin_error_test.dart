// Unit test for the response-body parser surfaced by #1162. Pin/unpin used
// to show the same `Failed to pin message` toast regardless of what the
// server said. The parser pulls `error` out of the JSON body so the real
// reason (DM not allowed, non-admin, conversation not found) reaches the
// user.

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/chat_panel/message_actions.dart';

void main() {
  group('parsePinErrorMessage', () {
    test('returns server error when JSON body contains an error field', () {
      expect(
        parsePinErrorMessage(
          '{"error": "Only admins can pin in this group"}',
          'Failed to pin message',
        ),
        'Only admins can pin in this group',
      );
    });

    test('falls back when the body is empty / no error field', () {
      expect(
        parsePinErrorMessage('{}', 'Failed to pin message'),
        'Failed to pin message',
      );
    });

    test('falls back when error field is an empty string', () {
      expect(
        parsePinErrorMessage('{"error": ""}', 'Failed to unpin message'),
        'Failed to unpin message',
      );
    });

    test('falls back when body is non-JSON (HTML error page)', () {
      expect(
        parsePinErrorMessage(
          '<html><body>500 Internal Server Error</body></html>',
          'Failed to pin message',
        ),
        'Failed to pin message',
      );
    });

    test('falls back when body is not a JSON map', () {
      expect(
        parsePinErrorMessage('"oops"', 'Failed to pin message'),
        'Failed to pin message',
      );
    });
  });
}
