import 'package:echo_app/src/services/media_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stableMediaCacheKey', () {
    test('strips query params so auth tokens do not cause cache misses', () {
      const url =
          'https://us-east.echo-messenger.us/api/users/42/avatar?ticket=abc123';
      expect(
        stableMediaCacheKey(url),
        'https://us-east.echo-messenger.us/api/users/42/avatar',
      );
    });

    test('leaves URLs without query params unchanged', () {
      const url = 'https://us-east.echo-messenger.us/api/users/42/avatar';
      expect(stableMediaCacheKey(url), url);
    });

    test('does not leave a trailing ? on query-stripped URLs', () {
      const url =
          'https://us-east.echo-messenger.us/api/users/42/avatar?v=12345';
      final key = stableMediaCacheKey(url);
      expect(key.endsWith('?'), isFalse);
      expect(key, 'https://us-east.echo-messenger.us/api/users/42/avatar');
    });

    test('strips multiple query params', () {
      const url =
          'https://us-east.echo-messenger.us/api/users/42/avatar?v=1&size=lg';
      expect(
        stableMediaCacheKey(url),
        'https://us-east.echo-messenger.us/api/users/42/avatar',
      );
    });

    test('returns the input unchanged for non-parseable strings', () {
      const bad = 'not a url :::';
      expect(stableMediaCacheKey(bad), bad);
    });

    test('is stable: same output for repeated calls', () {
      const url = 'https://us-east.echo-messenger.us/api/users/42/avatar';
      expect(stableMediaCacheKey(url), stableMediaCacheKey(url));
    });
  });
}
