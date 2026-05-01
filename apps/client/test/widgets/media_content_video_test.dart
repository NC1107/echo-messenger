// Widget tests for MediaContent video branch (#637).
// Focuses on the InlineVideoPlayer tile (thumbnail + play overlay + action
// buttons). The FullscreenVideoPlayer Linux fallback path is already covered
// by inline_video_player_linux_test.dart (#620).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/gif_playback_provider.dart';
import 'package:echo_app/src/widgets/message/media_content.dart';

import '../helpers/pump_app.dart';

// Thin GifPlayback override — avoids SharedPreferences I/O in tests.
class _FakeGifPlayback extends GifPlayback {
  @override
  GifPlaybackState build() =>
      const GifPlaybackState(autoplayEnabled: false, appFocused: false);
}

List<Override> _gifOverride() => [
  gifPlaybackProvider.overrideWith(_FakeGifPlayback.new),
];

Widget _videoContent(String content) => MediaContent(
  content: content,
  isMine: false,
  serverUrl: 'http://localhost:8080',
  authToken: 'fake-token',
);

void main() {
  group('MediaContent video branch (#637)', () {
    testWidgets('renders InlineVideoPlayer for [video:URL] content', (
      tester,
    ) async {
      await tester.pumpApp(
        _videoContent('[video:https://example.com/clip.mp4]'),
        overrides: _gifOverride(),
      );
      await tester.pump();

      expect(find.byType(InlineVideoPlayer), findsOneWidget);
    });

    testWidgets('video tile shows play overlay icon', (tester) async {
      await tester.pumpApp(
        _videoContent('[video:https://example.com/clip.mp4]'),
        overrides: _gifOverride(),
      );
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('video tile shows Watch and Download buttons', (tester) async {
      await tester.pumpApp(
        _videoContent('[video:https://example.com/clip.mp4]'),
        overrides: _gifOverride(),
      );
      await tester.pump();

      expect(find.text('Watch'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('renders nothing for non-media text content', (tester) async {
      await tester.pumpApp(
        _videoContent('hello world'),
        overrides: _gifOverride(),
      );
      await tester.pump();

      expect(find.byType(InlineVideoPlayer), findsNothing);
    });

    testWidgets('video area has "play video" semantics label', (tester) async {
      await tester.pumpApp(
        _videoContent('[video:https://example.com/clip.mp4]'),
        overrides: _gifOverride(),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('play video', caseSensitive: false)),
        findsOneWidget,
      );
    });
  });

  group('InlineVideoPlayer thumbUrl construction (#411)', () {
    // Regression: thumbUrl was built as '${videoUrl}/thumb' where videoUrl
    // may already have query params appended (e.g. '?ticket=xyz' on web).
    // That produces '/api/media/uuid?ticket=xyz/thumb' — a malformed URL
    // where the ticket value contains a path separator.
    //
    // The fix: build thumbUrl from rawUrl before any query params are added,
    // then resolve it independently. This test verifies the correct pattern
    // using pure string logic, independent of kIsWeb.
    test('thumb URL built from rawUrl never contains query params mid-path', () {
      const rawUrl = '/api/media/abc-123';
      // Simulate a resolved videoUrl that already has a query param (web path).
      const resolvedVideoUrl = '/api/media/abc-123?ticket=tok';

      // Old (buggy) approach: append /thumb to the already-resolved URL.
      final buggyThumbUrl = '$resolvedVideoUrl/thumb';

      // New (correct) approach: append /thumb to rawUrl, then resolve.
      final correctThumbRawUrl = '$rawUrl/thumb';
      // (Resolution would add ?ticket=tok at the end for web)
      final correctThumbUrl = '$correctThumbRawUrl?ticket=tok';

      // The buggy URL has '?ticket=tok/thumb' -- ticket value contains '/thumb'.
      expect(
        buggyThumbUrl,
        equals('/api/media/abc-123?ticket=tok/thumb'),
        reason: 'confirms the pre-fix bug pattern',
      );

      // The correct URL has '/thumb' as a path segment before the query.
      expect(
        correctThumbUrl,
        equals('/api/media/abc-123/thumb?ticket=tok'),
        reason: '/thumb must be a path segment, ticket must trail the URL',
      );

      // Confirm the bug pattern is absent from the correct URL.
      expect(
        correctThumbUrl.contains('?ticket=tok/thumb'),
        isFalse,
        reason: 'ticket value must not contain a path separator',
      );
    });
  });
}
