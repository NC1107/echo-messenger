import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Tracks which youtube-nocookie view-type ids have already been
/// registered. `registerViewFactory` throws on duplicate registration
/// so we guard with this set.
final Set<String> _registeredViewTypes = <String>{};

/// Returns an [HtmlElementView] that mounts a `youtube-nocookie.com`
/// iframe pointing at [videoId]. Lazy by construction: the widget is
/// only built after the user clicks the thumbnail in [YouTubeEmbed],
/// so the third-party iframe (and its scripts/cookies) never load
/// until the user opts in.
///
/// Privacy:
/// - `youtube-nocookie.com` defers tracking cookies until the user
///   actually starts playback inside the iframe.
/// - `rel=0` keeps related-video suggestions to the same channel.
/// - `modestbranding=1` removes the YouTube watermark.
/// - `autoplay=1` is safe here because the view is only created after
///   an explicit user gesture.
Widget? buildYouTubeIframe(String videoId) {
  final viewType = 'youtube-nocookie-$videoId';

  if (!_registeredViewTypes.contains(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final iframe = web.HTMLIFrameElement()
        ..src =
            'https://www.youtube-nocookie.com/embed/$videoId'
            '?autoplay=1&rel=0&modestbranding=1'
        ..allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen'
        ..allowFullscreen = true
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%';
      return iframe;
    });
    _registeredViewTypes.add(viewType);
  }

  return HtmlElementView(viewType: viewType);
}

/// True when the current platform can render an inline YouTube player.
const bool youtubeInlinePlaybackSupported = true;
