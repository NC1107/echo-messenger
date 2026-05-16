// Smoke-level regression guard for #910.
//
// The full toggleScreenShare() flow requires a connected LiveKit Room with
// real WebRTC internals, which is not available in a unit-test process.
// Instead this file opens the source file as text and asserts that both fix
// fields are present as literal source code.  A refactor that renames the
// fields or changes their values will break this test before it can reach CI.
//
// If the LiveKit client ever ships a testable mock Room, migrate the assertion
// to an integration-level call-site check.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('screen_share_actions.dart publish options (#910)', () {
    late String source;

    setUpAll(() {
      // Flutter unit tests run with Directory.current pointing at the package
      // root (apps/client/) when invoked via `flutter test`.  Walk into lib/
      // from there to locate the source file.
      final packageRoot = Directory.current.path;
      final sourceFile = File(
        [
          packageRoot,
          'lib',
          'src',
          'screens',
          'voice_lounge',
          'screen_share_actions.dart',
        ].join(Platform.pathSeparator),
      );

      if (!sourceFile.existsSync()) {
        throw StateError(
          'screen_share_actions.dart not found at ${sourceFile.path}. '
          'Run this test with `flutter test` from inside apps/client/.',
        );
      }
      source = sourceFile.readAsStringSync();
    });

    test('VideoPublishOptions contains simulcast: false '
        '(single-layer guard for remote viewers)', () {
      expect(
        source,
        contains('simulcast: false'),
        reason:
            'Removing simulcast: false from VideoPublishOptions breaks '
            'screen-share for remote viewers on macOS/Windows (#910).',
      );
    });

    test("VideoPublishOptions contains videoCodec: 'vp8' "
        '(cross-platform decode guard)', () {
      expect(
        source,
        contains("videoCodec: 'vp8'"),
        reason:
            "Removing videoCodec: 'vp8' from VideoPublishOptions lets the "
            'SFU select a codec that flutter_webrtc cannot decode everywhere '
            '(#910).',
      );
    });

    test(
      'Both options appear inside the same VideoPublishOptions constructor block',
      () {
        // Find the VideoPublishOptions constructor and confirm both fields sit
        // between its opening '(' and closing ')'.
        final optionsStart = source.indexOf('VideoPublishOptions(');
        expect(
          optionsStart,
          isNot(-1),
          reason: 'VideoPublishOptions constructor not found in source',
        );

        // Find the closing paren of the options block.  Use a simple scan
        // that handles nested parens so future refactors don't false-positive.
        var depth = 0;
        var optionsEnd = -1;
        for (var i = optionsStart; i < source.length; i++) {
          if (source[i] == '(') {
            depth++;
          } else if (source[i] == ')') {
            depth--;
            if (depth == 0) {
              optionsEnd = i;
              break;
            }
          }
        }
        expect(
          optionsEnd,
          isNot(-1),
          reason:
              'Could not find matching closing paren for VideoPublishOptions',
        );

        final block = source.substring(optionsStart, optionsEnd + 1);
        expect(
          block,
          contains('simulcast: false'),
          reason: 'simulcast: false must be inside VideoPublishOptions(…)',
        );
        expect(
          block,
          contains("videoCodec: 'vp8'"),
          reason: "videoCodec: 'vp8' must be inside VideoPublishOptions(…)",
        );
      },
    );
  });
}
