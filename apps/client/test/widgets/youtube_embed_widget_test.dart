// Widget-level tests for YouTubeEmbed (#637).
// The static extractId() logic is covered separately in youtube_embed_test.dart.
// These tests focus on the widget tree shape using the fallback card path,
// which is always active on the Linux test host (youtubeIframeSupported=false).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/youtube_embed.dart';

import '../helpers/pump_app.dart';

void main() {
  group('YouTubeEmbed widget (#637)', () {
    testWidgets('renders fallback card with play icon for a valid video ID', (
      tester,
    ) async {
      await tester.pumpApp(const YouTubeEmbed(videoId: 'dQw4w9WgXcQ'));
      await tester.pump();

      // The fallback card always shows a red circular play button.
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      // "YouTube" badge label appears in the thumbnail overlay.
      expect(find.text('YouTube'), findsOneWidget);
    });

    testWidgets('shows optional title when provided', (tester) async {
      await tester.pumpApp(
        const YouTubeEmbed(
          videoId: 'dQw4w9WgXcQ',
          title: 'Never Gonna Give You Up',
        ),
      );
      await tester.pump();

      expect(find.text('Never Gonna Give You Up'), findsOneWidget);
    });

    testWidgets('renders without title when title is null', (tester) async {
      await tester.pumpApp(const YouTubeEmbed(videoId: 'dQw4w9WgXcQ'));
      await tester.pump();

      // Widget tree must exist — the fallback card is always rendered.
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('extractId returns null for non-YouTube URLs', (tester) async {
      // Static method — no pump needed, but kept in the widget group for
      // discoverability alongside the render tests.
      expect(YouTubeEmbed.extractId('https://vimeo.com/123456789'), isNull);
      expect(YouTubeEmbed.extractId('not a url at all'), isNull);
    });

    testWidgets('extractId parses valid YouTube URL formats', (tester) async {
      expect(
        YouTubeEmbed.extractId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeEmbed.extractId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeEmbed.extractId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });
  });
}
