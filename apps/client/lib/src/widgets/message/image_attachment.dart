/// Inline image attachment widget with aspect-ratio reservation.
///
/// When [imageWidth] and [imageHeight] are provided (from the server-side
/// dimension metadata), the widget reserves the exact aspect ratio before any
/// bytes arrive, eliminating the bubble-jump that occurs when the image loads
/// into a zero-height placeholder.
///
/// When dimensions are absent (legacy messages predating the migration, or
/// non-PNG/JPEG formats where imagesize cannot read the header), the widget
/// falls back to the previous behaviour: a fixed-height skeleton while loading.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/media_cache_service.dart';

// ---------------------------------------------------------------------------
// Session-scoped dimension cache
// ---------------------------------------------------------------------------

/// Stores known pixel dimensions for image URLs within the current app session.
///
/// This map is pre-populated by the upload path (via [cacheImageDimensions])
/// immediately after the server returns dimensions in the upload DTO, so that
/// [ImageAttachment] can reserve the correct aspect-ratio placeholder even on
/// the first render — before any bytes have arrived.
///
/// Entries persist for the lifetime of the app process. The map is bounded in
/// practice by the number of images uploaded or loaded per session.
final Map<String, Size> imageDimensionCache = {};

/// Register [width] × [height] for [url] so [ImageAttachment] can use them
/// for placeholder sizing on first render.
///
/// Call this immediately after a successful image upload (when the server DTO
/// returns dimensions). The [url] should be the relative server path (e.g.
/// `/api/media/<uuid>`) so it matches the key used during rendering.
void cacheImageDimensions(String url, int width, int height) {
  imageDimensionCache[url] = Size(width.toDouble(), height.toDouble());
}

/// The maximum inline width for an image bubble.
const double kImageBubbleMaxWidth = 300.0;

/// The fallback height used when dimensions are not known.
const double kImageBubbleFallbackHeight = 200.0;

/// The minimum clamped height for the loading skeleton.
const double _kSkeletonMinHeight = 80.0;

/// The maximum clamped height for the loading skeleton.
const double _kSkeletonMaxHeight = 400.0;

/// Renders a single image attachment inside a chat bubble.
///
/// - If [imageWidth] and [imageHeight] are non-null, wraps the image in an
///   [AspectRatio] so the bubble reserves exactly the right space before bytes
///   arrive.
/// - Uses [Image.network]'s `loadingBuilder` equivalent via
///   [CachedNetworkImage]'s `placeholder` to show a skeleton tinted with
///   [Theme.colorScheme.surfaceContainerHighest] while bytes are in flight.
/// - Falls back to a 200px tall skeleton when dimensions are unknown.
class ImageAttachment extends StatelessWidget {
  const ImageAttachment({
    super.key,
    required this.imageUrl,
    required this.headers,
    this.imageWidth,
    this.imageHeight,
    this.memCacheWidth,
  });

  /// The fully resolved image URL (with auth ticket on web).
  final String imageUrl;

  /// Auth headers for native platforms (empty on web).
  final Map<String, String> headers;

  /// Pixel width returned by the server at upload time. May be null for
  /// legacy messages or formats where dimension extraction was skipped.
  final int? imageWidth;

  /// Pixel height returned by the server at upload time. May be null.
  final int? imageHeight;

  /// Optional memory cache width for resolution capping (DPR * display width).
  final int? memCacheWidth;

  @override
  Widget build(BuildContext context) {
    // Prefer explicit dimensions; fall back to the session-scoped cache
    // (pre-populated by the upload path or by prior renders).
    final cached = imageDimensionCache[imageUrl];
    final resolvedWidth = imageWidth ?? cached?.width.toInt();
    final resolvedHeight = imageHeight ?? cached?.height.toInt();

    // Cache-key keying: stripping the entire query string is too aggressive
    // because the media-ticket on web flips between two states (null → fresh
    // ticket) over the lifetime of a single chat session. A first render
    // before the ticket arrives produces a no-ticket URL that 401s; once the
    // ticket lands and the widget rebuilds with a ?ticket=… URL the
    // image lookup HIT against the poisoned cache slot and the user sees
    // [Image failed to load] permanently (#1094). Include a coarse
    // ticket-bucket in the cache key so the failed-without-auth attempt
    // doesn't poison the with-auth fetch.
    final hasTicketSuffix =
        Uri.tryParse(imageUrl)?.queryParameters.containsKey('ticket') == true;
    final cachedImage = CachedNetworkImage(
      imageUrl: imageUrl,
      cacheKey:
          '${stableMediaCacheKey(imageUrl)}#${hasTicketSuffix ? 'auth' : 'noauth'}',
      cacheManager: chatMediaCacheManager,
      width: kImageBubbleMaxWidth,
      fit: BoxFit.cover,
      httpHeaders: headers,
      memCacheWidth: memCacheWidth,
      imageBuilder: (_, imageProvider) => Image(
        image: imageProvider,
        fit: BoxFit.cover,
        width: kImageBubbleMaxWidth,
      ),
      errorWidget: (_, _, _) => Container(
        width: kImageBubbleMaxWidth,
        height: _kSkeletonMinHeight,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            '[Image failed to load]',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ),
      ),
      placeholder: (_, _) => _skeleton(context, resolvedWidth, resolvedHeight),
    );

    // When dimensions are known, wrap in AspectRatio so the bubble reserves
    // the exact pixel proportion before any bytes arrive.
    if (resolvedWidth != null && resolvedHeight != null) {
      return AspectRatio(
        aspectRatio: resolvedWidth / resolvedHeight,
        child: cachedImage,
      );
    }

    return cachedImage;
  }

  /// Builds the loading skeleton. When [w] and [h] are known the height is
  /// derived from the aspect ratio; otherwise a fixed fallback height is used.
  Widget _skeleton(BuildContext context, int? w, int? h) {
    final double placeholderHeight;
    if (w != null && h != null) {
      placeholderHeight = (kImageBubbleMaxWidth * h / w).clamp(
        _kSkeletonMinHeight,
        _kSkeletonMaxHeight,
      );
    } else {
      placeholderHeight = kImageBubbleFallbackHeight;
    }
    return Container(
      width: kImageBubbleMaxWidth,
      height: placeholderHeight,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}
