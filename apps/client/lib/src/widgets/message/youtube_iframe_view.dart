// Cross-platform shim for the inline YouTube iframe player.
//
// On web (`dart.library.html`) we render a privacy-respecting
// `youtube-nocookie.com` iframe through a Flutter `HtmlElementView`.
// On every other platform there is no in-process browser engine we can
// trust, so the stub returns `null` and the embed widget falls back to
// launching the system YouTube app / browser.
export 'youtube_iframe_view_stub.dart'
    if (dart.library.html) 'youtube_iframe_view_web.dart';
