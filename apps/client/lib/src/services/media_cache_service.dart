import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Single named disk cache shared by all chat image and avatar widgets.
///
/// Using one manager ensures the same image is never re-fetched regardless
/// of which widget (thumbnail, gallery, avatar) displays it.
///
/// Config:
/// - 500 objects max on disk
/// - 30-day stale period
final chatMediaCacheManager = CacheManager(
  Config(
    'chatMedia',
    maxNrOfCacheObjects: 500,
    stalePeriod: const Duration(days: 30),
  ),
);

/// Derives a stable cache key from a URL by stripping query parameters.
///
/// Auth tokens, media tickets, and nonces change between requests and would
/// cause cache misses even when the underlying file hasn't changed. Using
/// only the URL path as the key guarantees hits on repeated loads.
String stableMediaCacheKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.replace(queryParameters: {}).toString();
}
