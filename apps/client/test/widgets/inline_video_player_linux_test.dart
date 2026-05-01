import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/media_content.dart';

import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildPlayer({required bool isLinux}) => FullscreenVideoPlayer(
  videoUrl: 'https://example.com/video.mp4',
  rawUrl: '/media/video.mp4',
  headers: const {},
  accent: Colors.purple,
  textMuted: Colors.grey,
  onLaunchExternal: () {},
  isLinuxOverride: isLinux,
);

// ---------------------------------------------------------------------------
// Tests — issue #620
// ---------------------------------------------------------------------------

void main() {
  group('FullscreenVideoPlayer Linux fallback (#620)', () {
    testWidgets(
      'shows unsupported fallback immediately on Linux without crashing',
      (tester) async {
        await tester.pumpApp(_buildPlayer(isLinux: true));
        // One pump is enough — the fallback is synchronous (no async init).
        await tester.pump();

        // The error state's icon and "Open externally" button must be visible.
        expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
        expect(find.text('Open externally'), findsOneWidget);

        // The Linux-specific message must be present in the widget tree.
        expect(
          find.textContaining('not supported on Linux desktop'),
          findsOneWidget,
        );

        // No loading spinner — we never entered the async init path.
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('does not show Linux-specific message when isLinux is false', (
      tester,
    ) async {
      await tester.pumpApp(_buildPlayer(isLinux: false));
      // Allow the async _init() to run. In the test environment video_player
      // has no platform implementation, so init() throws UnimplementedError
      // and the widget lands in the generic error state — but it must NOT
      // show the Linux-specific message (that is only injected by the Linux
      // guard added for #620).
      await tester.pumpAndSettle();

      // The Linux-specific message must NOT appear.
      expect(
        find.textContaining('not supported on Linux desktop'),
        findsNothing,
      );
    });
  });
}
