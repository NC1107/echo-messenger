import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../providers/gif_playback_provider.dart';
import '../../services/media_cache_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/download_helper.dart';
import 'voice_message_widget.dart';

/// Regex for detecting image markers: [img:URL]
final _imgRegex = RegExp(r'^\[img:(.+)\]$');

/// Regex for detecting video markers: [video:URL]
final _videoRegex = RegExp(r'^\[video:(.+)\]$');

/// Regex for detecting generic file markers: [file:URL]
final _fileRegex = RegExp(r'^\[file:(.+)\]$');

/// Regex for detecting audio markers: [audio:URL]
final _audioRegex = RegExp(r'^\[audio:(.+)\]$');

/// Regex for detecting standalone URL messages.
final _standaloneUrlRegex = RegExp(r'^https?://[^\s]+$', caseSensitive: false);

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp'};
const _videoExtensions = {'mp4', 'webm', 'mov'};
const _audioExtensions = {'mp3', 'ogg', 'wav', 'm4a', 'aac'};
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
      _audioExtensions.contains(ext) ||
      _fileExtensions.contains(ext);
}

/// Returns true if the URL points to a known video extension.
bool isVideoUrl(String url) => _videoExtensions.contains(urlExtension(url));

/// Returns true if the URL points to a known image extension.
bool isImageUrl(String url) => _imageExtensions.contains(urlExtension(url));

/// Returns true if the URL points to a known file extension.
bool isFileUrl(String url) => _fileExtensions.contains(urlExtension(url));

/// Returns true if the URL points to a known audio extension.
bool isAudioUrl(String url) => _audioExtensions.contains(urlExtension(url));

/// Resolves a potentially relative media URL to an absolute URL.
///
/// On web, appends a short-lived media ticket (not the JWT) because
/// CachedNetworkImage uses HTML <img> elements which cannot send custom
/// HTTP headers.  This prevents JWT leakage into browser history, server
/// logs, and Referer headers.  On native platforms, callers use
/// [mediaHeaders] instead.
String resolveMediaUrl(
  String url, {
  String? serverUrl,
  String? authToken,
  String? mediaTicket,
}) {
  String resolved = url;
  if (!url.startsWith('http')) {
    final base = serverUrl ?? '';
    if (url.startsWith('/') && base.isNotEmpty) {
      resolved = '$base$url';
    }
  }
  // On web, <img> tags cannot carry Authorization headers, so pass a
  // media ticket via query parameter.  Tickets are scoped to media only
  // and expire after 5 minutes (unlike JWTs which grant full API access).
  if (kIsWeb && mediaTicket != null && mediaTicket.isNotEmpty) {
    final separator = resolved.contains('?') ? '&' : '?';
    resolved = '$resolved${separator}ticket=$mediaTicket';
  }
  return resolved;
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

  final audioMatch = _audioRegex.firstMatch(content);
  if (audioMatch != null) return audioMatch.group(1);

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
///
/// Returns empty headers on web since auth is passed via URL query parameter.
Map<String, String> mediaHeaders({String? authToken}) {
  if (kIsWeb) return const {};
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
  final String? mediaTicket;

  /// Called when the user taps an image with the resolved full URL.
  /// When null, the widget falls back to opening its own single-image dialog.
  final void Function(String resolvedUrl)? onImageTap;

  const MediaContent({
    super.key,
    required this.content,
    required this.isMine,
    this.serverUrl,
    this.authToken,
    this.mediaTicket,
    this.onImageTap,
  });

  @override
  State<MediaContent> createState() => MediaContentState();
}

class MediaContentState extends State<MediaContent> {
  static final Map<String, Size> _imageSizeCache = {};

  String _resolveUrl(String url) => resolveMediaUrl(
    url,
    serverUrl: widget.serverUrl,
    authToken: widget.authToken,
    mediaTicket: widget.mediaTicket,
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
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (dialogContext) {
        return Stack(
          children: [
            // Dismiss layer — tapping black region closes the viewer.
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(dialogContext).pop(),
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(dialogContext).size.width * 0.85,
                  maxHeight: MediaQuery.of(dialogContext).size.height * 0.85,
                ),
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: GestureDetector(
                    // Tap on the image (or its letterbox padding) dismisses
                    // the viewer. Pinch / pan are different gesture kinds
                    // and still flow up to InteractiveViewer.
                    onTap: () => Navigator.of(dialogContext).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: imageUrl.endsWith('.gif')
                        ? Image(
                            image: CachedNetworkImageProvider(
                              imageUrl,
                              cacheKey: stableMediaCacheKey(imageUrl),
                              cacheManager: chatMediaCacheManager,
                              headers: headers,
                            ),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white54,
                                size: 48,
                              ),
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: imageUrl,
                            cacheKey: stableMediaCacheKey(imageUrl),
                            cacheManager: chatMediaCacheManager,
                            httpHeaders: headers,
                            fit: BoxFit.contain,
                            placeholder: (_, _) => const SizedBox(
                              width: 320,
                              height: 240,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                ),
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
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
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
            onTap: () => widget.onImageTap != null
                ? widget.onImageTap!(fullUrl)
                : showImageViewer(imageUrl: fullUrl),
            child: Stack(
              children: [
                fullUrl.startsWith('http') && urlExtension(rawUrl) == 'gif'
                    ? Consumer(
                        builder: (ctx, ref, _) {
                          final gif = ref.watch(gifPlaybackProvider);
                          if (gif.isAnimating) {
                            // Route GIF playback through the disk cache so
                            // switching conversations doesn't re-fetch the
                            // animation each time (#562).
                            return Image(
                              image: CachedNetworkImageProvider(
                                fullUrl,
                                cacheKey: stableMediaCacheKey(rawUrl),
                                cacheManager: chatMediaCacheManager,
                                headers: _headers(),
                              ),
                              width: 300,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, e, st) => _gifErrorPlaceholder(
                                context,
                                'GIF failed to load',
                              ),
                            );
                          }
                          return _PausedGifPlaceholder(
                            width: 300,
                            onTap: () => widget.onImageTap != null
                                ? widget.onImageTap!(fullUrl)
                                : showImageViewer(imageUrl: fullUrl),
                          );
                        },
                      )
                    : CachedNetworkImage(
                        imageUrl: fullUrl,
                        cacheKey: stableMediaCacheKey(fullUrl),
                        cacheManager: chatMediaCacheManager,
                        width: 300,
                        fit: BoxFit.cover,
                        httpHeaders: headers,
                        imageBuilder: (ctx, imageProvider) {
                          if (!_imageSizeCache.containsKey(fullUrl)) {
                            imageProvider
                                .resolve(const ImageConfiguration())
                                .addListener(
                                  ImageStreamListener((info, _) {
                                    _imageSizeCache[fullUrl] = Size(
                                      info.image.width.toDouble(),
                                      info.image.height.toDouble(),
                                    );
                                  }),
                                );
                          }
                          return Image(
                            image: imageProvider,
                            fit: BoxFit.cover,
                            width: 300,
                          );
                        },
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
                        placeholder: (_, _) {
                          final cached = _imageSizeCache[fullUrl];
                          final h = cached != null
                              ? (300 * cached.height / cached.width).clamp(
                                  80.0,
                                  400.0,
                                )
                              : 200.0;
                          return Container(
                            width: 300,
                            height: h,
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
                          );
                        },
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
      return Semantics(
        label: 'File attachment: $displayName',
        child: Container(
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
        ),
      );
    }

    // --- Audio ---
    final audioMatch = _audioRegex.firstMatch(content);
    final audioUrl =
        audioMatch?.group(1) ??
        (standaloneUrl != null && isAudioUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (audioUrl != null) {
      final rawUrl = audioUrl;
      final fullUrl = _resolveUrl(rawUrl);
      return Semantics(
        label: 'Voice message',
        child: VoiceMessageWidget(
          audioUrl: fullUrl,
          headers: _headers(),
          isMine: widget.isMine,
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
  /// Open the fullscreen player. Routes through a self-contained dialog
  /// that owns its own [VideoPlayerController] — so a failure here doesn't
  /// silently fall back to the external browser the way the inline path
  /// used to. The dialog renders its own loading + error states and only
  /// offers a "Open externally" affordance after init has actually failed.
  void _openInApp() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      useSafeArea: false,
      builder: (dialogContext) => FullscreenVideoPlayer(
        videoUrl: widget.videoUrl,
        rawUrl: widget.rawUrl,
        headers: widget.headers,
        accent: context.accent,
        textMuted: context.textMuted,
        onLaunchExternal: widget.onOpen,
      ),
    );
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
                  onPressed: _openInApp,
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text('Watch'),
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

  /// Static play-thumbnail. Tapping always opens the self-contained
  /// fullscreen player. We deliberately don't init a controller inline
  /// anymore — it created a confusing "inline mini-player vs fullscreen
  /// player" duality and quietly fell through to the system browser when
  /// init failed.
  Widget _buildVideoArea() {
    return Semantics(
      label: 'play video',
      button: true,
      child: GestureDetector(
        onTap: _openInApp,
        child: Container(
          height: 170,
          color: widget.mainBg,
          child: Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.55),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Padding(
                // Optical centering: the play triangle's mass sits left of
                // its bounding box, so nudge it right by 2px.
                padding: EdgeInsets.only(left: 2),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Self-contained fullscreen video player. Owns its own
/// [VideoPlayerController] so it doesn't depend on the inline bubble's init
/// succeeding first. Renders three states: loading, playing, and error
/// (with a clear "Open externally" affordance for codec / auth failures).
class FullscreenVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String rawUrl;
  final Map<String, String> headers;
  final Color accent;
  final Color textMuted;

  /// Called from the error state's "Open externally" button. Typically
  /// wired to the same launcher the bubble's Download button uses.
  final VoidCallback onLaunchExternal;

  const FullscreenVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.rawUrl,
    required this.headers,
    required this.accent,
    required this.textMuted,
    required this.onLaunchExternal,
  });

  @override
  State<FullscreenVideoPlayer> createState() => _FullscreenVideoPlayerState();
}

class _FullscreenVideoPlayerState extends State<FullscreenVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initFailed = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
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
      controller.addListener(_onUpdate);
      setState(() => _controller = controller);
      controller.play();
    } catch (e) {
      debugPrint(
        '[FullscreenVideoPlayer] init failed for ${widget.rawUrl}: $e',
      );
      if (mounted) {
        setState(() {
          _initFailed = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onUpdate);
    _controller?.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  String _formatDuration(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = _controller;

    Widget body;
    if (_initFailed) {
      body = _buildErrorState();
    } else if (c == null) {
      body = _buildLoadingState();
    } else {
      body = _buildPlayer(c);
    }

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          body,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close fullscreen',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: widget.accent,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Loading video…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white54,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              "Couldn't play this video in app",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Unknown player error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onLaunchExternal();
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open externally'),
              style: FilledButton.styleFrom(
                backgroundColor: widget.accent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer(VideoPlayerController c) {
    final position = c.value.position;
    final duration = c.value.duration;
    final progress = (duration.inMilliseconds > 0)
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Stack(
      children: [
        Center(
          child: GestureDetector(
            onTap: _togglePlayPause,
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio.clamp(0.3, 5.0),
              child: VideoPlayer(c),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: widget.accent,
                        inactiveTrackColor: widget.textMuted.withValues(
                          alpha: 0.3,
                        ),
                        thumbColor: widget.accent,
                      ),
                      child: Slider(
                        value: progress,
                        onChanged: (v) {
                          final ms = (v * duration.inMilliseconds).round();
                          c.seekTo(Duration(milliseconds: ms));
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Centered error card shown when a GIF fails to load. Mirrors the look of
/// the "image failed to load" placeholder so failures don't visually jar.
Widget _gifErrorPlaceholder(BuildContext context, String label) {
  return Container(
    width: 300,
    height: 80,
    decoration: BoxDecoration(
      color: context.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Center(
      child: Text(
        '[$label]',
        style: TextStyle(color: context.textMuted, fontSize: 13),
      ),
    ),
  );
}

/// Static placeholder shown in place of an animated GIF when autoplay is
/// off (or the app has lost focus). Tapping opens the fullscreen viewer
/// where the GIF is always allowed to animate.
class _PausedGifPlaceholder extends StatelessWidget {
  final double width;
  final VoidCallback onTap;

  const _PausedGifPlaceholder({required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: 160,
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border, width: 1),
        ),
        child: Stack(
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: context.accentLight,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: context.accent, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow, size: 16, color: context.accent),
                    const SizedBox(width: 6),
                    Text(
                      'Tap to play',
                      style: TextStyle(
                        color: context.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'GIF',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
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
