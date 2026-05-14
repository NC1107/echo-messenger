import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/youtube_oembed_service.dart';
import '../../theme/echo_theme.dart';
import 'youtube_iframe_view.dart';

/// 16:9 YouTube embed (#734).
///
/// Renders a thumbnail card with a red play button and -- once the
/// public YouTube oEmbed endpoint responds -- the video title and
/// uploader. Tap behaviour depends on the platform:
///
///  - **Web**: the thumbnail is swapped in-place for a
///    `youtube-nocookie.com` iframe (click-to-load: no third-party
///    scripts or cookies load before the user opts in).
///  - **Desktop & mobile**: tapping launches the YouTube app
///    (deep-link) or the system browser. We do not pull in a webview
///    plugin for Linux/desktop because YouTube blocks many otherwise
///    public videos inside iframes (region locks, age gates, embedding
///    disabled by uploader) and renders its branded "Video unavailable"
///    UI without firing a JS error event we can intercept. The card +
///    title + external launch is faster and more reliable, consistent
///    with how Discord and Slack handle YouTube links.
class YouTubeEmbed extends StatefulWidget {
  final String videoId;

  /// Optional override for the title. When non-null, [oembedService] is
  /// never invoked -- useful for tests and for callers that already have
  /// the title from somewhere else.
  final String? title;

  /// Optional service injection. Tests pass a service backed by a
  /// mocked [http.Client]; production callers omit this and the widget
  /// builds the default service on demand.
  final YouTubeOEmbedService? oembedService;

  const YouTubeEmbed({
    super.key,
    required this.videoId,
    this.title,
    this.oembedService,
  });

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
  /// Title resolved from oEmbed; null while loading or on failure.
  String? _resolvedTitle;
  String? _resolvedAuthor;

  /// True once the user has clicked the thumbnail and we have swapped
  /// to the inline iframe (web only). Stays false on every other
  /// platform; the click handler launches the external app instead.
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _maybeFetchTitle();
  }

  /// Fires the oEmbed lookup. Skipped when the caller already passed a
  /// non-empty [widget.title] or when a cached result is available.
  void _maybeFetchTitle() {
    if (widget.title != null && widget.title!.isNotEmpty) return;

    final service = widget.oembedService ?? YouTubeOEmbedService();
    final cached = service.cached(widget.videoId);
    if (cached != null) {
      _resolvedTitle = cached.title;
      _resolvedAuthor = cached.authorName;
      return;
    }

    service.fetch(widget.videoId).then((data) {
      if (!mounted || data == null) return;
      setState(() {
        _resolvedTitle = data.title;
        _resolvedAuthor = data.authorName;
      });
    });
  }

  /// Effective title: the explicit prop wins over the oEmbed lookup.
  String? get _title {
    if (widget.title != null && widget.title!.isNotEmpty) return widget.title;
    return _resolvedTitle;
  }

  Future<void> _launchVideo() async {
    final videoId = widget.videoId;
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

  void _onTap() {
    if (youtubeInlinePlaybackSupported) {
      // Swap thumbnail for the youtube-nocookie iframe. The iframe is
      // built lazily so no third-party scripts load before this gesture.
      setState(() => _playing = true);
    } else {
      _launchVideo();
    }
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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
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
                    child: _playing
                        ? (buildYouTubeIframe(widget.videoId) ?? _thumbnail())
                        : _thumbnail(),
                  ),
                  _buildMeta(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail() {
    return Semantics(
      label: youtubeInlinePlaybackSupported
          ? 'Play YouTube video'
          : 'Open YouTube video',
      button: true,
      child: InkWell(
        onTap: _onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Thumbnail(videoId: widget.videoId),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    );
  }

  Widget _buildMeta(BuildContext context) {
    final title = _title;
    if (title == null || title.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (_resolvedAuthor != null && _resolvedAuthor!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _resolvedAuthor!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
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
