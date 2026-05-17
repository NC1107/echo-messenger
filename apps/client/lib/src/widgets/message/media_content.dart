import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../providers/gif_playback_provider.dart';
import '../../services/media_cache_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/download_helper.dart';
import 'image_attachment.dart';
import 'video_player.dart';
import 'voice_message_widget.dart';

// Markers may be followed by a newline + caption (the seed script and the
// chat input both produce `[img:URL]\nCaption`), so the regex is anchored at
// the start, uses a lazy capture, and does NOT require the closing `]` to
// be at end-of-string. See #795.

/// Regex for detecting image markers: [img:URL]
final _imgRegex = RegExp(r'^\[img:([^\]\n]+)\]');

/// Regex for detecting video markers: [video:URL]
final _videoRegex = RegExp(r'^\[video:([^\]\n]+)\]');

/// Regex for detecting generic file markers: [file:URL]
final _fileRegex = RegExp(r'^\[file:([^\]\n]+)\]');

/// Regex for detecting audio markers: [audio:URL]
final _audioRegex = RegExp(r'^\[audio:([^\]\n]+)\]');

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

/// Extracts the caption that follows a media marker on the first line.
///
/// Returns the trimmed text after the closing `]` of an `[img:]` / `[video:]`
/// / `[file:]` / `[audio:]` marker, or `null` if there is no marker or no
/// caption. Used so messages of the form `[img:URL]\nCaption` render both the
/// inline media and the caption text below it.
String? extractMediaCaption(String content) {
  for (final regex in [_imgRegex, _videoRegex, _fileRegex, _audioRegex]) {
    final match = regex.firstMatch(content);
    if (match == null) continue;
    final rest = content.substring(match.end).trim();
    return rest.isEmpty ? null : rest;
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
        // Decode at most the screen-sized resolution so the image cache
        // doesn't hold a 4K JPEG in RAM for a 1920px viewport (#639).
        final dpr = MediaQuery.devicePixelRatioOf(dialogContext);
        final viewerCacheWidth = (MediaQuery.sizeOf(dialogContext).width * dpr)
            .round();
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
                            // ResizeImage caps decode resolution to the
                            // viewport (#639) — cheaper than holding a
                            // 4K GIF in RAM for a 1920px viewer.
                            image: ResizeImage(
                              CachedNetworkImageProvider(
                                imageUrl,
                                cacheKey: stableMediaCacheKey(imageUrl),
                                cacheManager: chatMediaCacheManager,
                                headers: headers,
                              ),
                              width: viewerCacheWidth,
                              policy: ResizeImagePolicy.fit,
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
                            // Cap decode resolution to the viewport (#639).
                            memCacheWidth: viewerCacheWidth,
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
                            // Cap decode at 300px * DPR so a 4K GIF
                            // doesn't get fully decoded for a 300px
                            // bubble (#639).
                            final dpr = MediaQuery.devicePixelRatioOf(ctx);
                            return Image(
                              image: ResizeImage(
                                CachedNetworkImageProvider(
                                  fullUrl,
                                  cacheKey: stableMediaCacheKey(rawUrl),
                                  cacheManager: chatMediaCacheManager,
                                  headers: _headers(),
                                ),
                                width: (300 * dpr).round(),
                                policy: ResizeImagePolicy.fit,
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
                    : ImageAttachment(
                        imageUrl: fullUrl,
                        headers: headers,
                        // Cap decode at 300px * DPR so a 4K JPEG isn't
                        // held in RAM at full size for a 300px inline
                        // bubble (#639).
                        memCacheWidth:
                            (300 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
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
      // Build thumbUrl from rawUrl (not the already-resolved videoUrl) so that
      // on web the ?ticket= is appended after /thumb, not before it (#411).
      final rawThumbUrl = '$rawUrl/thumb';
      return InlineVideoPlayer(
        videoUrl: _resolveUrl(rawUrl),
        thumbUrl: _resolveUrl(rawThumbUrl),
        rawUrl: rawUrl,
        headers: _headers(),
        surface: context.surface,
        mainBg: context.mainBg,
        border: context.border,
        onOpen: () => openMedia(rawUrl),
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

// Added by Claude

/// The kind of attachment a message content string represents.
enum ReplyAttachmentKind { image, gif, video, audio, file, none }

/// Classifies content into a ReplyAttachmentKind.
ReplyAttachmentKind replyAttachmentKind(String content) {
  final trimmed = content.trim();
  if (trimmed.startsWith("[img:")) {
    final url = _imgRegex.firstMatch(trimmed)?.group(1) ?? "";
    if (url.toLowerCase().endsWith(".gif")) return ReplyAttachmentKind.gif;
    return ReplyAttachmentKind.image;
  }
  if (trimmed.startsWith("[video:")) return ReplyAttachmentKind.video;
  if (trimmed.startsWith("[audio:")) return ReplyAttachmentKind.audio;
  if (trimmed.startsWith("[file:")) return ReplyAttachmentKind.file;
  final mediaUrl = extractMediaUrl(trimmed);
  if (mediaUrl != null) {
    final ext = urlExtension(mediaUrl);
    if (ext == "gif") return ReplyAttachmentKind.gif;
    if (_imageExtensions.contains(ext)) return ReplyAttachmentKind.image;
    if (_videoExtensions.contains(ext)) return ReplyAttachmentKind.video;
    if (_audioExtensions.contains(ext)) return ReplyAttachmentKind.audio;
    if (_fileExtensions.contains(ext)) return ReplyAttachmentKind.file;
    if (mediaUrl.contains("/api/media/")) return ReplyAttachmentKind.image;
  }
  // Bare /api/media/ URL without a recognised extension (no marker).
  if (trimmed.startsWith("http") && trimmed.contains("/api/media/")) {
    return ReplyAttachmentKind.image;
  }
  return ReplyAttachmentKind.none;
}
