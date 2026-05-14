import 'package:flutter/widgets.dart';

/// Inline YouTube playback is web-only. On every other platform this
/// returns `null` and the caller falls back to launching the link in
/// the system YouTube app / browser.
///
/// We intentionally do not depend on `webview_flutter` here -- it has
/// no first-party Linux desktop backend, and prior experience showed
/// that even where it works, YouTube blocks many embeds with a branded
/// "Video unavailable" error inside the iframe (see the historical
/// note in `youtube_embed.dart`).
Widget? buildYouTubeIframe(String videoId) => null;

/// True when the current platform can render an inline YouTube player.
const bool youtubeInlinePlaybackSupported = false;
