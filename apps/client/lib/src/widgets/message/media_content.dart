import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/download_helper.dart';

/// Regex for detecting image markers: [img:URL]
final _imgRegex = RegExp(r'^\[img:(.+)\]$');

/// Regex for detecting video markers: [video:URL]
final _videoRegex = RegExp(r'^\[video:(.+)\]$');

/// Regex for detecting generic file markers: [file:URL]
final _fileRegex = RegExp(r'^\[file:(.+)\]$');

/// Regex for detecting standalone URL messages.
final _standaloneUrlRegex = RegExp(r'^https?://[^\s]+$', caseSensitive: false);

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp'};
const _videoExtensions = {'mp4', 'webm', 'mov'};
const _fileExtensions = {'pdf'};

/// Regex for image extensions in URLs (used for inline embed detection).
final imageUrlEmbedRegex = RegExp(
  r'https?://[^\s]+\.(?:gif|png|jpe?g|webp)',
  caseSensitive: false,
);

/// Returns the file extension from a URL path, lowercased.
String urlExtension(String url) {
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? '';
  if (path.isEmpty || !path.contains('.')) return '';
  return path.split('.').last.toLowerCase();
}

/// Returns true if the content is a standalone URL pointing to a known media
/// type (image, video, or file).
bool isStandaloneMediaUrl(String content) {
  final trimmed = content.trim();
  if (!_standaloneUrlRegex.hasMatch(trimmed)) return false;

  final ext = urlExtension(trimmed);
  return _imageExtensions.contains(ext) ||
      _videoExtensions.contains(ext) ||
      _fileExtensions.contains(ext);
}

/// Returns true if the URL points to a known video extension.
bool isVideoUrl(String url) => _videoExtensions.contains(urlExtension(url));

/// Returns true if the URL points to a known image extension.
bool isImageUrl(String url) => _imageExtensions.contains(urlExtension(url));

/// Returns true if the URL points to a known file extension.
bool isFileUrl(String url) => _fileExtensions.contains(urlExtension(url));

/// Resolves a potentially relative media URL to an absolute URL.
///
/// Does NOT append auth tokens -- callers should use [mediaHeaders] for
/// authenticated requests, or fetch a media ticket for browser-opened URLs.
String resolveMediaUrl(String url, {String? serverUrl, String? authToken}) {
  if (url.startsWith('http')) return url;
  final base = serverUrl ?? '';
  return url.startsWith('/') && base.isNotEmpty ? '$base$url' : url;
}

/// Fetches a single-use media ticket from the server for use in browser URLs.
Future<String?> _fetchMediaTicket({
  required String serverUrl,
  required String authToken,
}) async {
  try {
    final response = await http.post(
      Uri.parse('$serverUrl/api/media/ticket'),
      headers: {'Authorization': 'Bearer $authToken'},
    );
    if (response.statusCode == 200) {
      final data = (response.body.contains('{'))
          ? Uri.splitQueryString(response.body)
          : {};
      // Parse JSON manually to avoid adding dart:convert import dependency
      // when it may already be imported. The response is {"ticket":"..."}.
      final match = RegExp(
        r'"ticket"\s*:\s*"([^"]+)"',
      ).firstMatch(response.body);
      return match?.group(1) ?? data['ticket'];
    }
  } catch (_) {
    // Ticket fetch failed -- fall through to direct open.
  }
  return null;
}

/// Extracts a media URL from message content, checking for [img:], [video:],
/// [file:] markers and standalone media URLs.
String? extractMediaUrl(String content) {
  final imageMatch = _imgRegex.firstMatch(content);
  if (imageMatch != null) return imageMatch.group(1);

  final videoMatch = _videoRegex.firstMatch(content);
  if (videoMatch != null) return videoMatch.group(1);

  final fileMatch = _fileRegex.firstMatch(content);
  if (fileMatch != null) return fileMatch.group(1);

  if (isStandaloneMediaUrl(content)) {
    return content.trim();
  }

  return null;
}

/// Extract image URLs embedded within text (not standalone).
List<String> extractEmbeddedImageUrls(String content) {
  if (isStandaloneMediaUrl(content)) return [];
  if (_imgRegex.hasMatch(content)) return [];
  return imageUrlEmbedRegex
      .allMatches(content)
      .map((m) => m.group(0)!)
      .toList();
}

/// Builds auth headers for media requests.
Map<String, String> mediaHeaders({String? authToken}) {
  final headers = <String, String>{};
  if (authToken != null && authToken.isNotEmpty) {
    headers['Authorization'] = 'Bearer $authToken';
  }
  return headers;
}

String _filenameFromUrl(String url) {
  final parsed = Uri.tryParse(url);
  final lastSegment = (parsed?.pathSegments.isNotEmpty ?? false)
      ? parsed!.pathSegments.last
      : '';
  if (lastSegment.isEmpty) {
    return 'media.bin';
  }
  return lastSegment;
}

/// A widget that renders media content (images, videos, files) from message
/// content strings. Returns null from [build] when the content is not media.
class MediaContent extends StatefulWidget {
  final String content;
  final bool isMine;
  final String? serverUrl;
  final String? authToken;

  const MediaContent({
    super.key,
    required this.content,
    required this.isMine,
    this.serverUrl,
    this.authToken,
  });

  @override
  State<MediaContent> createState() => MediaContentState();
}

class MediaContentState extends State<MediaContent> {
  String _resolveUrl(String url) => resolveMediaUrl(
    url,
    serverUrl: widget.serverUrl,
    authToken: widget.authToken,
  );

  Map<String, String> _headers() => mediaHeaders(authToken: widget.authToken);

  // ignore: public_member_api_docs
  Future<void> openMedia(String rawUrl) async {
    final baseUrl = _resolveUrl(rawUrl);

    // Fetch a single-use media ticket so the browser can authenticate
    // without leaking the JWT in the URL.
    String url = baseUrl;
    final serverUrl = widget.serverUrl;
    final token = widget.authToken;
    if (serverUrl != null &&
        serverUrl.isNotEmpty &&
        token != null &&
        token.isNotEmpty) {
      final ticket = await _fetchMediaTicket(
        serverUrl: serverUrl,
        authToken: token,
      );
      if (ticket != null) {
        url = '$baseUrl?ticket=$ticket';
      }
    }

    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ignore: public_member_api_docs
  Future<void> downloadMedia(String rawUrl) async {
    final url = _resolveUrl(rawUrl);
    try {
      final response = await http.get(Uri.parse(url), headers: _headers());
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
      final downloaded = await saveBytesAsFile(
        fileName: _filenameFromUrl(url),
        bytes: response.bodyBytes,
        mimeType: contentType,
      );

      if (!mounted) return;
      if (downloaded) {
        ToastService.show(context, 'Download started', type: ToastType.success);
        return;
      }

      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ToastService.show(
        context,
        'Save not supported here yet. Link copied.',
        type: ToastType.info,
      );
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not download media',
        type: ToastType.error,
      );
    }
  }

  // ignore: public_member_api_docs
  void showImageViewer({required String imageUrl}) {
    final headers = _headers();
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (dialogContext) {
        final screenSize = MediaQuery.of(dialogContext).size;
        final maxWidth = screenSize.width * 0.8;
        final maxHeight = screenSize.height * 0.8;
        return GestureDetector(
          onTap: () => Navigator.of(dialogContext).pop(),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb taps on the image itself
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: Stack(
                  children: [
                    InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: Center(
                        child: CachedNetworkImage(
                          imageUrl: imageUrl,
                          httpHeaders: headers,
                          fit: BoxFit.contain,
                          placeholder: (_, _) => const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                          errorWidget: (_, _, _) => const Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white54,
                              size: 48,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.download_outlined),
                            color: Colors.white,
                            tooltip: 'Download',
                            onPressed: () => downloadMedia(imageUrl),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            color: Colors.white,
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(dialogContext).pop(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Builds the media widget, or returns null if the content is not media.
  Widget? buildMedia() {
    final content = widget.content;
    final headers = _headers();

    final standaloneUrl = isStandaloneMediaUrl(content) ? content.trim() : null;

    // --- Image ---
    final imageMatch = _imgRegex.firstMatch(content);
    final imageUrl =
        imageMatch?.group(1) ??
        (standaloneUrl != null && isImageUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (imageUrl != null) {
      final rawUrl = imageUrl;
      final fullUrl = _resolveUrl(rawUrl);

      return Semantics(
        label: 'Image attachment. Tap to view full size.',
        image: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: () => showImageViewer(imageUrl: fullUrl),
            child: Stack(
              children: [
                fullUrl.startsWith('http') && urlExtension(rawUrl) == 'gif'
                    ? Image.network(
                        fullUrl,
                        width: 300,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, e, st) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              '[GIF failed to load]',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: fullUrl,
                        width: 300,
                        fit: BoxFit.cover,
                        httpHeaders: headers,
                        errorWidget: (_, e, st) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              '[Image failed to load]',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        placeholder: (_, _) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.open_in_full,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // --- Video ---
    final videoMatch = _videoRegex.firstMatch(content);
    final videoUrl =
        videoMatch?.group(1) ??
        (standaloneUrl != null && isVideoUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (videoUrl != null) {
      final rawUrl = videoUrl;
      return InlineVideoPlayer(
        videoUrl: _resolveUrl(rawUrl),
        rawUrl: rawUrl,
        headers: _headers(),
        surface: context.surface,
        mainBg: context.mainBg,
        border: context.border,
        textPrimary: context.textPrimary,
        textMuted: context.textMuted,
        onOpen: () => openMedia(rawUrl),
        onDownload: () => downloadMedia(rawUrl),
      );
    }

    // --- File ---
    final fileMatch = _fileRegex.firstMatch(content);
    final fileUrl =
        fileMatch?.group(1) ??
        (standaloneUrl != null && isFileUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (fileUrl != null) {
      final rawUrl = fileUrl;
      final displayName = _filenameFromUrl(rawUrl);
      return Container(
        width: 300,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.mainBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.insert_drive_file_outlined,
                color: context.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 18),
              onPressed: () => downloadMedia(rawUrl),
              tooltip: 'Download',
            ),
          ],
        ),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return buildMedia() ?? const SizedBox.shrink();
  }
}

/// Inline video player widget with play/pause controls and download
/// fallback. Initialises a [VideoPlayerController] on first build and
/// disposes it when removed from the tree.
class InlineVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String rawUrl;
  final Map<String, String> headers;
  final Color surface;
  final Color mainBg;
  final Color border;
  final Color textPrimary;
  final Color textMuted;
  final VoidCallback onOpen;
  final VoidCallback onDownload;

  const InlineVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.rawUrl,
    required this.headers,
    required this.surface,
    required this.mainBg,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
    required this.onOpen,
    required this.onDownload,
  });

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initFailed = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
        httpHeaders: widget.headers,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      debugPrint('[InlineVideoPlayer] init failed for ${widget.rawUrl}: $e');
      if (mounted) setState(() => _initFailed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: _buildVideoArea(),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onOpen,
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('Open'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onDownload,
                  icon: const Icon(Icons.download_outlined, size: 14),
                  label: const Text('Download'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    final c = _controller;

    // Still loading
    if (c == null && !_initFailed) {
      return Container(
        height: 170,
        color: widget.mainBg,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: widget.textMuted,
            ),
          ),
        ),
      );
    }

    // Init failed -- show static placeholder
    if (_initFailed || c == null) {
      return GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          height: 170,
          color: widget.mainBg,
          child: Center(
            child: Icon(
              Icons.play_circle_outline,
              size: 44,
              color: widget.textMuted,
            ),
          ),
        ),
      );
    }

    // Initialised -- show player with controls
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: c.value.aspectRatio.clamp(0.5, 3.0),
            child: VideoPlayer(c),
          ),
          if (!c.value.isPlaying)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow,
                size: 32,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}
