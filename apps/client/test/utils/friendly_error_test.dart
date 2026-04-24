import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/friendly_error.dart';

void main() {
  group('friendlyError', () {
    test('SocketException maps to network-unreachable message', () {
      final msg = friendlyError(const SocketException('Failed host lookup'));
      expect(msg, "Can't reach Echo. Check your internet connection.");
    });

    test('TimeoutException maps to slow-server message', () {
      final msg = friendlyError(TimeoutException('timed out'));
      expect(msg, 'Echo is taking too long to respond. Try again.');
    });

    test('FormatException maps to bad-response message', () {
      final msg = friendlyError(const FormatException('not json'));
      expect(msg, 'The server returned an unexpected response.');
    });

    test('413 in message maps to file-too-large', () {
      final msg = friendlyError(
        Exception('Server responded 413 Payload Too Large'),
      );
      expect(msg, 'That file is too large.');
    });

    test('429 in message maps to rate-limit', () {
      final msg = friendlyError(Exception('got 429 Too Many Requests'));
      expect(msg, 'Too many requests. Slow down.');
    });

    test('5xx in message maps to temporarily-unavailable', () {
      expect(
        friendlyError(Exception('Server error 503 Service Unavailable')),
        'Echo is temporarily unavailable. Try again in a moment.',
      );
      expect(
        friendlyError(Exception('500 internal')),
        'Echo is temporarily unavailable. Try again in a moment.',
      );
    });

    test('unknown exception falls through to generic message', () {
      final msg = friendlyError(Exception('something weird happened'));
      expect(msg, 'Something went wrong. Try again.');
    });

    test('does not match 3-digit number that is not a 5xx status', () {
      // 404 and 200 should not trigger the 5xx branch.
      expect(
        friendlyError(Exception('status 404')),
        'Something went wrong. Try again.',
      );
      expect(
        friendlyError(Exception('status 200')),
        'Something went wrong. Try again.',
      );
    });
  });
}
