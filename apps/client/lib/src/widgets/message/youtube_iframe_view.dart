// Web uses youtube-nocookie.com HtmlElementView; other platforms get the stub (falls back to launching system browser).
export 'youtube_iframe_view_stub.dart'
    if (dart.library.html) 'youtube_iframe_view_web.dart';
