import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/debug_log.dart';

void main() {
  group('debugLog', () {
    test('outputs message via debugPrint in debug mode', () {
      // In test mode kDebugMode is true, so debugLog should forward to
      // debugPrint. Capture the output by overriding debugPrint.
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };

      try {
        debugLog('hello world');
        expect(captured, ['hello world']);
      } finally {
        debugPrint = original;
      }
    });

    test('prepends tag when provided', () {
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };

      try {
        debugLog('something happened', 'WebSocket');
        expect(captured, ['[WebSocket] something happened']);
      } finally {
        debugPrint = original;
      }
    });

    test('works without tag', () {
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };

      try {
        debugLog('bare message');
        expect(captured, ['bare message']);
      } finally {
        debugPrint = original;
      }
    });
  });
}
