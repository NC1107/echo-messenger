// Smoke-level regression guards for #910 and #12.
//
// The full toggleScreenShare() flow requires a connected LiveKit Room with
// real WebRTC internals, which is not available in a unit-test process.
// Instead this file opens the source file as text and asserts that structural
// invariants are present as literal source code.  A refactor that removes
// these properties will break this test before it can reach CI.
//
// If the LiveKit client ever ships a testable mock Room, migrate the assertion
// to an integration-level call-site check.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('screen_share_actions.dart publish options (#910)', () {
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

  group('screen_share_actions.dart Linux picker path (#12)', () {
    test('_useLiveKitPicker returns true for Platform.isLinux', () {
      // Guard: if Linux is removed from the picker condition the portal fallback
      // path re-enables, which fails with "source not found" when xdg-desktop-
      // portal is not running or returns no source (#12).
      expect(
        source,
        contains('Platform.isLinux'),
        reason:
            'Linux must be listed in _useLiveKitPicker so it uses the custom '
            'EchoScreenSelectDialog instead of the unreliable xdg-desktop-portal '
            'path (#12).',
      );
    });

    test('_useLiveKitPicker includes Linux alongside macOS and Windows', () {
      // Confirm all three desktop platforms are guarded in a single condition.
      final macIdx = source.indexOf('Platform.isMacOS');
      final winIdx = source.indexOf('Platform.isWindows');
      final linIdx = source.indexOf('Platform.isLinux');
      expect(macIdx, isNot(-1), reason: 'Platform.isMacOS not found');
      expect(winIdx, isNot(-1), reason: 'Platform.isWindows not found');
      expect(linIdx, isNot(-1), reason: 'Platform.isLinux not found');

      // All three references must appear within the _useLiveKitPicker function.
      // Locate the function body by finding the first opening brace after its
      // declaration and scanning to the matching closing brace.
      final fnStart = source.indexOf('bool _useLiveKitPicker()');
      expect(fnStart, isNot(-1), reason: '_useLiveKitPicker not found');
      var depth = 0;
      var fnEnd = -1;
      for (var i = fnStart; i < source.length; i++) {
        if (source[i] == '{') {
          depth++;
        } else if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            fnEnd = i;
            break;
          }
        }
      }
      expect(
        fnEnd,
        isNot(-1),
        reason: 'Could not find end of _useLiveKitPicker',
      );

      final fn = source.substring(fnStart, fnEnd + 1);
      expect(
        fn,
        contains('Platform.isMacOS'),
        reason: 'macOS missing from picker guard',
      );
      expect(
        fn,
        contains('Platform.isWindows'),
        reason: 'Windows missing from picker guard',
      );
      expect(
        fn,
        contains('Platform.isLinux'),
        reason: 'Linux missing from picker guard',
      );
    });
  });

  group('screen_share_actions.dart re-entrancy guard (#mobile-voice)', () {
    test('toggleScreenShare gates on a library-level in-flight flag', () {
      // The 3-taps-to-share regression on iOS was caused by repeated
      // setScreenShareEnabled calls landing while ReplayKit was still
      // settling. Removing the in-flight guard re-enables the
      // regression.
      expect(
        source,
        contains('_toggleInFlight'),
        reason:
            'toggleScreenShare must keep a library-level in-flight flag so '
            'rapid taps cannot stack setScreenShareEnabled calls '
            '(#mobile-voice).',
      );
      expect(
        source,
        contains('if (_toggleInFlight)'),
        reason:
            'toggleScreenShare must early-return when a previous toggle is '
            'still running.',
      );
    });

    test(
      'toggleScreenShare yields after stop on iOS so ReplayKit can settle',
      () {
        // Without the post-stop delay the next start tap collides with
        // the outgoing broadcast extension and the user gets
        // "Recording interrupted by another application".
        expect(
          source,
          contains('_iosBroadcastSettle'),
          reason:
              'toggleScreenShare must await an iOS settle delay between '
              'stop and accepting the next toggle (#mobile-voice).',
        );
        expect(
          source,
          contains('Platform.isIOS'),
          reason:
              'The settle delay must be gated on iOS so other platforms '
              'do not pay the cost.',
        );
      },
    );

    test('_startScreenShareNative resets provider state when start fails', () {
      // If setScreenShareEnabled returns false (picker dismissed,
      // permission denied, ReplayKit interrupted) the provider's
      // isScreenSharing flag must stay false — otherwise the next
      // tap hits the stop path instead of retrying, and the user has
      // to tap a third time.
      //
      // Locate the function body to keep the assertion narrowly
      // scoped instead of matching the substring anywhere in the
      // file.
      final fnStart = source.indexOf('Future<void> _startScreenShareNative(');
      expect(fnStart, isNot(-1), reason: '_startScreenShareNative not found');
      final braceStart = source.indexOf('{', fnStart);
      var depth = 0;
      var fnEnd = -1;
      for (var i = braceStart; i < source.length; i++) {
        if (source[i] == '{') {
          depth++;
        } else if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            fnEnd = i;
            break;
          }
        }
      }
      expect(fnEnd, isNot(-1));
      final fn = source.substring(fnStart, fnEnd + 1);
      expect(
        fn,
        contains('setLiveKitScreenShareActive(false)'),
        reason:
            '_startScreenShareNative must clear the provider when the '
            'SDK reports start failure (#mobile-voice).',
      );
    });
  });
}
