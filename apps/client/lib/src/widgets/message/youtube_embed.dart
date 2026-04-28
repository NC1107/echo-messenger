import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../theme/echo_theme.dart';
import 'youtube_platform_support.dart';

/// 16:9 YouTube embed.
///
/// On platforms where `youtube_player_iframe` (and its underlying webview
/// implementation) is supported — iOS, Android, Web, macOS — this renders
/// the inline iframe player. On Linux + Windows desktop, or when iframe
/// init fails for any reason (network, ad-blocker, etc.), it falls back to
/// a static thumbnail card with a red play button overlay; tapping the
/// fallback launches YouTube via deep link or the system browser.
class YouTubeEmbed extends StatefulWidget {
  final String videoId;
  final String? title;

  const YouTubeEmbed({super.key, required this.videoId, this.title});

  static final RegExp _idRegex = RegExp(
    r'^https?://(?:www\.|m\.)?(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/shorts/|youtube\.com/embed/)([A-Za-z0-9_-]{11})',
    caseSensitive: false,
  );

  /// Extracts the 11-char video ID from a YouTube URL, or `null` if the URL
  /// is not a recognised YouTube watch / shorts / embed link.
  static String? extractId(String url) {
    final match = _idRegex.firstMatch(url.trim());
    return match?.group(1);
  }

  @override
  State<YouTubeEmbed> createState() => _YouTubeEmbedState();
}

class _YouTubeEmbedState extends State<YouTubeEmbed> {
  YoutubePlayerController? _controller;
  StreamSubscription<YoutubePlayerValue>? _subscription;
  bool _useFallback = !youtubeIframeSupported;

  @override
  void initState() {
    super.initState();
    if (youtubeIframeSupported) {
      try {
        final controller = YoutubePlayerController.fromVideoId(
          videoId: widget.videoId,
          autoPlay: false,
          params: const YoutubePlayerParams(
            mute: false,
            showControls: true,
            showFullscreenButton: true,
            strictRelatedVideos: true,
          ),
        );
        // Listen for runtime errors (video unavailable, embedding disabled,
        // owner removed, etc. — codes 100/101/105/150 plus the catch-all
        // `unknown` for other YouTube IFrame API errors). When YouTube
        // reports any non-`none` error, swap to the static fallback card so
        // the user gets a clean "tap to watch on YouTube" affordance
        // instead of YouTube's branded inline error UI.
        _subscription = controller.listen((value) {
          if (!mounted || _useFallback) return;
          if (value.error != YoutubeError.none) {
            debugPrint(
              '[YouTubeEmbed] runtime error ${value.error}, falling back',
            );
            setState(() => _useFallback = true);
          }
        });
        _controller = controller;
      } catch (e) {
        debugPrint('[YouTubeEmbed] iframe init failed: $e');
        _useFallback = true;
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_useFallback || controller == null) {
      return _YouTubeFallbackCard(videoId: widget.videoId, title: widget.title);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: context.surface,
            border: Border.all(color: context.border, width: 1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                // On web the iframe sits inside an HtmlElementView and the
                // outer GestureDetector on the chat bubble (long-press,
                // swipe-to-reply) wins the gesture arena before the iframe
                // sees the tap. PointerInterceptor draws a transparent HTML
                // element that intercepts pointer events at the DOM layer
                // so they reach the iframe's controls. No-op on native.
                child: kIsWeb
                    ? PointerInterceptor(
                        child: YoutubePlayer(
                          controller: controller,
                          aspectRatio: 16 / 9,
                          enableFullScreenOnVerticalDrag: false,
                        ),
                      )
                    : YoutubePlayer(
                        controller: controller,
                        aspectRatio: 16 / 9,
                        enableFullScreenOnVerticalDrag: false,
                      ),
              ),
              if (widget.title != null && widget.title!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Text(
                    widget.title!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Static thumbnail card. Used directly on Linux/Windows desktop where the
/// iframe player isn't supported, and as a fallback when iframe init fails
/// at runtime on supported platforms.
class _YouTubeFallbackCard extends StatelessWidget {
  final String videoId;
  final String? title;

  const _YouTubeFallbackCard({required this.videoId, this.title});

  static Future<void> _launchVideo(String videoId) async {
    final appUri = Uri.parse('youtube://watch?v=$videoId');
    final webUri = Uri.parse('https://www.youtube.com/watch?v=$videoId');
    try {
      if (await canLaunchUrl(appUri)) {
        await launchUrl(appUri);
        return;
      }
    } catch (_) {
      // Fall through to web launch.
    }
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _launchVideo(videoId),
          child: Container(
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.border, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Thumbnail(videoId: videoId),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.45),
                            ],
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFFF0000),
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'YouTube',
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
                if (title != null && title!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Text(
                      title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumbnail with a `maxresdefault.jpg → hqdefault.jpg` fallback chain.
/// `maxresdefault` is missing for many videos (older uploads, Shorts), so we
/// fall back to `hqdefault` which is generated for every video.
class _Thumbnail extends StatefulWidget {
  final String videoId;
  const _Thumbnail({required this.videoId});

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  bool _useFallback = false;

  String get _url {
    final quality = _useFallback ? 'hqdefault' : 'maxresdefault';
    return 'https://i.ytimg.com/vi/${widget.videoId}/$quality.jpg';
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) {
        if (!_useFallback) {
          // Re-render with hqdefault next frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _useFallback = true);
          });
        }
        return Container(color: context.mainBg);
      },
    );
  }
}
