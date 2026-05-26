/// `_isGif` heuristic — URLs ending in `.gif` route through `Image.network`
/// so animation plays; everything else still goes through `CachedNetworkImage`.
/// The helper is private so we exercise it through a small re-implementation
/// that mirrors the production logic.
library;

import 'package:flutter_test/flutter_test.dart';

bool isGifLikeForTesting(String url) {
  final lower = url.split('?').first.toLowerCase();
  return lower.endsWith('.gif');
}

void main() {
  test('detects .gif extension', () {
    expect(isGifLikeForTesting('https://example.com/sticker.gif'), isTrue);
  });

  test('detects .GIF (case-insensitive)', () {
    expect(isGifLikeForTesting('https://example.com/STICKER.GIF'), isTrue);
  });

  test('strips query strings before checking extension', () {
    expect(
      isGifLikeForTesting('https://cdn.example/foo.gif?v=123&x=y'),
      isTrue,
    );
  });

  test('returns false for static formats', () {
    expect(isGifLikeForTesting('https://example.com/foo.png'), isFalse);
    expect(isGifLikeForTesting('https://example.com/foo.jpg'), isFalse);
    expect(isGifLikeForTesting('https://example.com/foo.webp'), isFalse);
  });

  test('returns false when a path has gif in the middle but no extension', () {
    expect(isGifLikeForTesting('https://example.com/gifs/animation'), isFalse);
  });
}
