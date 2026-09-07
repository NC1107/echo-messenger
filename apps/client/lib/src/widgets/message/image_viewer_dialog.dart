import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/media_cache_service.dart';

/// Fullscreen, tap-to-dismiss, pinch-zoomable viewer for a single chat image.
///
/// Extracted from `MessageItem._showImageViewer` so the dialog is a reusable,
/// testable widget instead of an 80-line closure inside the message god-file.
/// The host stays the owner of auth headers and the download action and passes
/// them in via [headers] / [onDownload].
class ImageViewerDialog extends StatelessWidget {
  const ImageViewerDialog({
    super.key,
    required this.imageUrl,
    required this.headers,
    this.onDownload,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback? onDownload;

  /// Open the viewer as a modal dialog.
  static Future<void> show(
    BuildContext context, {
    required String imageUrl,
    required Map<String, String> headers,
    VoidCallback? onDownload,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(context).shadowColor.withValues(alpha: 0.9),
      builder: (_) => ImageViewerDialog(
        imageUrl: imageUrl,
        headers: headers,
        onDownload: onDownload,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    void dismiss() => Navigator.of(context).pop();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Image content — centered, constrained, does NOT fill the screen.
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: GestureDetector(
                onTap: dismiss,
                behavior: HitTestBehavior.opaque,
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  cacheKey: stableMediaCacheKey(imageUrl),
                  httpHeaders: headers,
                  cacheManager: chatMediaCacheManager,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => SizedBox(
                    width: 320,
                    height: 240,
                    child: Center(
                      child: CircularProgressIndicator(color: onPrimary),
                    ),
                  ),
                  errorWidget: (_, _, _) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: onPrimary.withValues(alpha: 0.54),
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onDownload != null)
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  color: onPrimary,
                  tooltip: 'Download',
                  onPressed: onDownload,
                ),
              IconButton(
                icon: const Icon(Icons.close),
                color: onPrimary,
                tooltip: 'Close',
                onPressed: dismiss,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
