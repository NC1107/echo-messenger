import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
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
  // Reconstruct without query or fragment to get a clean path-only key.
  // Passing `queryParameters: {}` to uri.replace() adds a trailing "?",
  // so we build a new Uri from its structural parts instead.
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// Evicts [fullUrl] from both the disk cache ([chatMediaCacheManager]) and
/// Flutter's in-memory [ImageCache].
///
/// Call this whenever an image at a stable URL is re-uploaded so that the
/// next render fetches fresh bytes instead of serving stale cached content.
/// The server reuses the same URL for avatar replacements
/// (e.g. `/api/users/<id>/avatar`), so without explicit eviction
/// [CachedNetworkImage] would continue to display the old photo indefinitely.
Future<void> evictAvatarFromCache(String fullUrl) async {
  // 1. Remove from disk cache (flutter_cache_manager).
  final cacheKey = stableMediaCacheKey(fullUrl);
  await chatMediaCacheManager.removeFile(cacheKey);

  // 2. Remove from Flutter's in-memory ImageCache so any in-flight decode
  //    is also discarded.
  final provider = CachedNetworkImageProvider(fullUrl, cacheKey: cacheKey);
  await provider.evict();

  // 3. Belt-and-suspenders: also clear the image from the global imageCache
  //    keyed by the bare URL (without query params) in case any widget built
  //    an Image.network or NetworkImage with the same URL directly.
  final networkProvider = NetworkImage(fullUrl);
  imageCache.evict(networkProvider);
}
