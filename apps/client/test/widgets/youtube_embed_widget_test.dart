// Widget-level tests for YouTubeEmbed (#637, #734).
// The static extractId() logic is covered separately in youtube_embed_test.dart.
// These tests focus on:
//  - widget tree shape using the fallback card path (always active on the
//    Linux test host because youtubeInlinePlaybackSupported=false there);
//  - optional oEmbed title fetch wiring (#734) -- title rendered after the
//    injected service resolves;
//  - lazy iframe contract (#734) -- thumbnail is what builds before the
//    user gestures, no platform view is materialised eagerly.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:echo_app/src/services/youtube_oembed_service.dart';
import 'package:echo_app/src/widgets/message/youtube_embed.dart';
import 'package:echo_app/src/widgets/message/youtube_iframe_view.dart';

import '../helpers/pump_app.dart';

void main() {
  group('YouTubeEmbed widget (#637, #734)', () {
    setUp(YouTubeOEmbedService.debugReset);

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

    testWidgets('shows optional title when provided directly', (tester) async {
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
      // No oEmbed service injected -- the default service hits the real
      // network, which is mocked out by Flutter test framework to fail.
      // We only check the card is rendered, not the eventual title.
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

    testWidgets('renders title fetched from oEmbed service (#734)', (
      tester,
    ) async {
      // Fake oEmbed endpoint that returns a Rick Astley title.
      final fakeClient = MockClient((req) async {
        expect(req.url.host, 'www.youtube.com');
        expect(req.url.path, '/oembed');
        return http.Response(
          jsonEncode({
            'title': 'Rick Astley - Never Gonna Give You Up',
            'author_name': 'Rick Astley',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await tester.pumpApp(
        YouTubeEmbed(
          videoId: 'dQw4w9WgXcQ',
          oembedService: YouTubeOEmbedService(client: fakeClient),
        ),
      );
      // Let the fetch future complete and the resulting setState flush.
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(
        find.text('Rick Astley - Never Gonna Give You Up'),
        findsOneWidget,
      );
      expect(find.text('Rick Astley'), findsOneWidget);
    });

    testWidgets('silently degrades when oEmbed returns non-200 (#734)', (
      tester,
    ) async {
      final fakeClient = MockClient((_) async => http.Response('error', 500));

      await tester.pumpApp(
        YouTubeEmbed(
          videoId: 'dQw4w9WgXcQ',
          oembedService: YouTubeOEmbedService(client: fakeClient),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Card still rendered, just no title row.
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('explicit title prop wins over oEmbed lookup (#734)', (
      tester,
    ) async {
      var fetched = false;
      final fakeClient = MockClient((_) async {
        fetched = true;
        return http.Response('{"title":"From network"}', 200);
      });

      await tester.pumpApp(
        YouTubeEmbed(
          videoId: 'dQw4w9WgXcQ',
          title: 'Caller-supplied title',
          oembedService: YouTubeOEmbedService(client: fakeClient),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Caller-supplied title'), findsOneWidget);
      expect(find.text('From network'), findsNothing);
      expect(
        fetched,
        isFalse,
        reason: 'oEmbed must be skipped when title is provided',
      );
    });

    testWidgets('iframe is not built before the user clicks (#734)', (
      tester,
    ) async {
      // On the Linux test host buildYouTubeIframe always returns null.
      // We still assert nothing extraordinary mounts before the click --
      // the thumbnail Image.network is the only thing in the 16:9 slot.
      await tester.pumpApp(const YouTubeEmbed(videoId: 'dQw4w9WgXcQ'));
      await tester.pump();

      // Pre-click: the InkWell wrapping the thumbnail must be present.
      expect(find.byType(InkWell), findsOneWidget);
      // The iframe view factory must be a no-op on this platform.
      expect(buildYouTubeIframe('dQw4w9WgXcQ'), isNull);
      expect(youtubeInlinePlaybackSupported, isFalse);
    });
  });

  group('YouTubeOEmbedService (#734)', () {
    setUp(YouTubeOEmbedService.debugReset);

    test('caches successful results in-memory', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{"title":"Cached"}', 200);
      });
      final svc = YouTubeOEmbedService(client: client);

      final first = await svc.fetch('abcdefghijk');
      final second = await svc.fetch('abcdefghijk');

      expect(first?.title, 'Cached');
      expect(second?.title, 'Cached');
      expect(calls, 1, reason: 'Second fetch must hit the in-memory cache');
    });

    test('does not cache failures', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('boom', 500);
      });
      final svc = YouTubeOEmbedService(client: client);

      expect(await svc.fetch('abcdefghijk'), isNull);
      expect(await svc.fetch('abcdefghijk'), isNull);
      expect(calls, 2, reason: 'Failures must remain retriable');
    });

    test('returns null on malformed JSON', () async {
      final client = MockClient((_) async => http.Response('not json', 200));
      final svc = YouTubeOEmbedService(client: client);
      expect(await svc.fetch('abcdefghijk'), isNull);
    });

    test('drops author_name when empty', () async {
      final client = MockClient(
        (_) async =>
            http.Response(jsonEncode({'title': 'T', 'author_name': ''}), 200),
      );
      final svc = YouTubeOEmbedService(client: client);
      final data = await svc.fetch('abcdefghijk');
      expect(data?.title, 'T');
      expect(data?.authorName, isNull);
    });
  });
}
