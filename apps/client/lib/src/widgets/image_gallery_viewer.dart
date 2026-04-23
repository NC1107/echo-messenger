import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/toast_service.dart';
import '../utils/download_helper.dart';

/// Opens a fullscreen swipeable image gallery over the current route.
///
/// [imageUrls] — ordered list of resolved image URLs to display.
/// [initialIndex] — index of the image that was tapped.
/// [headers] — optional HTTP headers (e.g. Authorization) for authenticated images.
void showImageGallery({
  required BuildContext context,
  required List<String> imageUrls,
  required int initialIndex,
  Map<String, String> headers = const {},
}) {
  assert(imageUrls.isNotEmpty, 'imageUrls must not be empty');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    builder: (_) => ImageGalleryViewer(
      imageUrls: imageUrls,
      initialIndex: initialIndex,
      headers: headers,
    ),
  );
}

/// Fullscreen image gallery with swipe-to-navigate, pinch-to-zoom, counter,
/// close button, and download button.
class ImageGalleryViewer extends StatefulWidget {
  final List<String> imageUrls;
  final int initialIndex;
  final Map<String, String> headers;

  const ImageGalleryViewer({
    super.key,
    required this.imageUrls,
    required this.initialIndex,
    this.headers = const {},
  });

  @override
  State<ImageGalleryViewer> createState() => _ImageGalleryViewerState();
}

class _ImageGalleryViewerState extends State<ImageGalleryViewer>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late int _currentIndex;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  /// Per-page transformation controllers so each page independently tracks
  /// zoom level. Needed to decide whether horizontal swipe changes pages
  /// or pans the zoomed image.
  final _transformControllers = <int, TransformationController>{};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.imageUrls.length - 1);
    _pageController = PageController(initialPage: _currentIndex);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fadeController.dispose();
    for (final tc in _transformControllers.values) {
      tc.dispose();
    }
    super.dispose();
  }

  TransformationController _controllerForPage(int index) =>
      _transformControllers.putIfAbsent(index, TransformationController.new);

  bool _pageIsZoomed(int index) {
    final tc = _transformControllers[index];
    if (tc == null) return false;
    return tc.value.getMaxScaleOnAxis() > 1.05;
  }

  void _close() {
    _fadeController.reverse().then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _download() async {
    final url = widget.imageUrls[_currentIndex];
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri, headers: widget.headers);

      if (!mounted) return;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        ToastService.show(
          context,
          'Download failed (${response.statusCode})',
          type: ToastType.error,
        );
        return;
      }

      final contentType =
          response.headers['content-type'] ?? 'application/octet-stream';
      final segments = uri.pathSegments;
      final fileName = (segments.isNotEmpty && segments.last.isNotEmpty)
          ? segments.last
          : 'image.jpg';

      final saved = await saveBytesAsFile(
        fileName: fileName,
        bytes: response.bodyBytes,
        mimeType: contentType,
      );

      if (!mounted) return;
      if (saved) {
        ToastService.show(context, 'Download started', type: ToastType.success);
      } else {
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        ToastService.show(
          context,
          'Save not supported here. Link copied.',
          type: ToastType.info,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not download image',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.imageUrls.length;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Material(
        color: Colors.black.withValues(alpha: 0.92),
        child: Stack(
          children: [
            // Full-screen page swipe area.
            Positioned.fill(
              child: PageView.builder(
                controller: _pageController,
                // When the current page is zoomed in, disable page-swipe so
                // horizontal drags pan the image instead of switching pages.
                physics: _pageIsZoomed(_currentIndex)
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemCount: total,
                itemBuilder: (_, index) => _GalleryPage(
                  imageUrl: widget.imageUrls[index],
                  headers: widget.headers,
                  transformationController: _controllerForPage(index),
                  onZoomChanged: () => setState(() {}),
                  onDismiss: _close,
                ),
              ),
            ),

            // Top bar: counter + close button.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      if (total > 1)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${_currentIndex + 1} of $total',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      const Spacer(),
                      // 44x44 close button.
                      Semantics(
                        label: 'Close image viewer',
                        button: true,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close, color: Colors.white),
                            tooltip: 'Close',
                            onPressed: _close,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom bar: prev arrow + download + next arrow.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Previous button — hidden when only one image.
                      if (total > 1)
                        Semantics(
                          label: 'Previous image',
                          button: true,
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                Icons.chevron_left,
                                size: 32,
                                color: _currentIndex > 0
                                    ? Colors.white
                                    : Colors.white30,
                              ),
                              onPressed: _currentIndex > 0
                                  ? () => _pageController.previousPage(
                                      duration: const Duration(
                                        milliseconds: 280,
                                      ),
                                      curve: Curves.easeInOut,
                                    )
                                  : null,
                            ),
                          ),
                        )
                      else
                        const SizedBox(width: 44),

                      // Download button — 44x44 touch target.
                      Semantics(
                        label: 'Download image',
                        button: true,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.download_outlined,
                              color: Colors.white,
                            ),
                            tooltip: 'Download',
                            onPressed: _download,
                          ),
                        ),
                      ),

                      // Next button — hidden when only one image.
                      if (total > 1)
                        Semantics(
                          label: 'Next image',
                          button: true,
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                Icons.chevron_right,
                                size: 32,
                                color: _currentIndex < total - 1
                                    ? Colors.white
                                    : Colors.white30,
                              ),
                              onPressed: _currentIndex < total - 1
                                  ? () => _pageController.nextPage(
                                      duration: const Duration(
                                        milliseconds: 280,
                                      ),
                                      curve: Curves.easeInOut,
                                    )
                                  : null,
                            ),
                          ),
                        )
                      else
                        const SizedBox(width: 44),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single gallery page
// ---------------------------------------------------------------------------

/// A single zoomable + drag-to-dismiss image page inside the gallery.
class _GalleryPage extends StatefulWidget {
  final String imageUrl;
  final Map<String, String> headers;
  final TransformationController transformationController;
  final VoidCallback onZoomChanged;
  final VoidCallback onDismiss;

  const _GalleryPage({
    required this.imageUrl,
    required this.headers,
    required this.transformationController,
    required this.onZoomChanged,
    required this.onDismiss,
  });

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  double _dragY = 0;
  bool _dismissing = false;

  bool get _isZoomed =>
      widget.transformationController.value.getMaxScaleOnAxis() > 1.05;

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_isZoomed) return; // let InteractiveViewer handle it while zoomed
    setState(() => _dragY += d.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_dismissing || _isZoomed) return;
    final fast = d.velocity.pixelsPerSecond.dy.abs() > 600;
    if (_dragY.abs() > 100 || fast) {
      setState(() => _dismissing = true);
      widget.onDismiss();
    } else {
      setState(() => _dragY = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fade the page as it is dragged away.
    final opacity = (1.0 - (_dragY.abs() / 280)).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: Duration.zero,
        child: Transform.translate(
          offset: Offset(0, _dragY),
          child: InteractiveViewer(
            transformationController: widget.transformationController,
            minScale: 0.8,
            maxScale: 6,
            onInteractionEnd: (_) => widget.onZoomChanged(),
            child: Center(child: _buildImage()),
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final url = widget.imageUrl;
    final lower = url.toLowerCase();
    final isGif = lower.contains('.gif');

    if (isGif) {
      return Image.network(
        url,
        headers: widget.headers,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const _BrokenImage(),
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : const _LoadingSpinner(),
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: widget.headers,
      fit: BoxFit.contain,
      placeholder: (_, _) => const _LoadingSpinner(),
      errorWidget: (_, _, _) => const _BrokenImage(),
    );
  }
}

class _LoadingSpinner extends StatelessWidget {
  const _LoadingSpinner();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 32,
      height: 32,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
    ),
  );
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) => const Center(
    child: Icon(Icons.broken_image_outlined, color: Colors.white38, size: 56),
  );
}
