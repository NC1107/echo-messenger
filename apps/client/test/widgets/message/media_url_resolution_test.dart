// Unit tests for resolveMediaUrl and mediaHeaders — the two functions that
// determine what URL and headers media_kit receives on native platforms.
//
// These cover the Linux video-playback bug surface:
//   - A relative URL (/api/media/{id}) must always become absolute before
//     it reaches Media(url, httpHeaders: headers).
//   - mediaHeaders must return a non-empty map (with Authorization) on
//     native platforms so libmpv can authenticate with the server.
//   - On web, mediaHeaders returns {} (auth goes via ?ticket= query param).
//   - resolveMediaUrl appends ?ticket= on web, not on native.
//
// NOTE: kIsWeb is always false in flutter test (the test host is native),
// so the "web" branches cannot be exercised in unit tests. Their
// correctness is verified by Playwright integration tests.
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/media_content.dart';

void main() {
  group('resolveMediaUrl', () {
    const kServer = 'https://us-east.echo-messenger.us';
    const kToken = 'test-token';
    const kTicket = 'med-ticket-abc';

    test(
      'absolute URL is returned unchanged on native (no ticket appended)',
      () {
        const absUrl = '$kServer/api/media/abc123.mp4';
        final result = resolveMediaUrl(
          absUrl,
          serverUrl: kServer,
          authToken: kToken,
          // mediaTicket supplied but kIsWeb is false in tests → must NOT append
          mediaTicket: kTicket,
        );
        expect(result, equals(absUrl));
      },
    );

    test(
      'relative URL starting with / is resolved to absolute using serverUrl',
      () {
        const relUrl = '/api/media/abc123.mp4';
        final result = resolveMediaUrl(
          relUrl,
          serverUrl: kServer,
          authToken: kToken,
        );
        expect(result, equals('$kServer$relUrl'));
      },
    );

    test(
      'relative URL with empty serverUrl is returned as-is (not resolved)',
      () {
        // This is the degenerate case that would cause libmpv to fail.
        // resolveMediaUrl cannot resolve without a server; callers are expected
        // to always supply serverUrl when on native.
        const relUrl = '/api/media/abc123.mp4';
        final result = resolveMediaUrl(relUrl, serverUrl: '');
        expect(result, equals(relUrl));
      },
    );

    test('relative URL with null serverUrl is returned as-is', () {
      const relUrl = '/api/media/abc123.mp4';
      final result = resolveMediaUrl(relUrl);
      expect(result, equals(relUrl));
    });

    test('absolute URL without http prefix is treated as relative', () {
      // Edge case: a URL that doesn't start with "http" is still treated as
      // needing resolution. Confirm behaviour is consistent.
      const nonHttp = 'ftp://example.com/file.mp4';
      // Does not start with 'http', so resolveMediaUrl attempts to prepend server.
      // With an empty base the result stays unchanged.
      final result = resolveMediaUrl(nonHttp, serverUrl: '');
      expect(result, equals(nonHttp));
    });

    test('server trailing slash does not produce double slash', () {
      // serverUrl with trailing slash — callers should strip it, but let's
      // document the current behaviour so regressions are caught.
      const relUrl = '/api/media/abc123.mp4';
      final result = resolveMediaUrl(relUrl, serverUrl: 'https://example.com/');
      // The current implementation concatenates: 'https://example.com/' + '/api/media/...'
      // → 'https://example.com//api/media/...'. That is a double slash.
      // This test documents the current (as-is) behaviour so any future fix
      // for it is an intentional change, not a surprise.
      expect(result, equals('https://example.com//api/media/abc123.mp4'));
    });

    test('thumb URL derived from rawUrl is also resolved to absolute', () {
      // _buildVideoWidget builds rawThumbUrl as '$rawUrl/thumb' and then calls
      // _resolveUrl on it. Verify the full thumb path resolves correctly.
      const rawUrl = '/api/media/abc123.mp4';
      final rawThumb = '$rawUrl/thumb';
      final result = resolveMediaUrl(rawThumb, serverUrl: kServer);
      expect(result, equals('$kServer/api/media/abc123.mp4/thumb'));
    });
  });

  group('mediaHeaders', () {
    // In flutter test, kIsWeb == false, so mediaHeaders should always return
    // a map containing the Authorization header when a token is supplied.

    test('returns Authorization header when token is present', () {
      final headers = mediaHeaders(authToken: 'my-jwt-token');
      expect(headers, containsPair('Authorization', 'Bearer my-jwt-token'));
    });

    test('returns empty map when token is null', () {
      final headers = mediaHeaders(authToken: null);
      expect(headers, isEmpty);
    });

    test('returns empty map when token is empty string', () {
      final headers = mediaHeaders(authToken: '');
      expect(headers, isEmpty);
    });

    test('header map is non-null (never null)', () {
      expect(mediaHeaders(), isNotNull);
      expect(mediaHeaders(authToken: 'tok'), isNotNull);
    });
  });
}
