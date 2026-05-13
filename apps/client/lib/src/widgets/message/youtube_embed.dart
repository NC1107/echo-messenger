import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/echo_theme.dart';

/// 16:9 YouTube embed.
///
/// Renders a static thumbnail card with a red play button overlay; tapping
/// launches the video in the YouTube app (deep-link) or, if the app isn't
/// installed, the system browser.
///
/// We deliberately don't use `youtube_player_iframe` for inline playback
/// any more. YouTube blocks many otherwise-public videos from embedding
/// (region locks, age gates, "embedding disabled by uploader") and renders
/// its branded "Video unavailable, error 152-N" UI inside the iframe
/// without firing a JS error event we can intercept. The result was 8
/// seconds of YouTube's branded error before the load timeout swapped to
/// this card. The card is faster, more reliable, and consistent with how
/// Discord/Slack handle YouTube links.
class YouTubeEmbed extends StatelessWidget {
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
      child: ConstrainedBox(
        // Cap width so the embed doesn't fill the full chat pane on desktop.
        // 400px matches approximately how Discord/Slack size inline embeds.
        constraints: const BoxConstraints(maxWidth: 400),
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
