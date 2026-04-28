// Whether `youtube_player_iframe` reliably supports the current platform.
//
// The package is backed by `webview_flutter`, which has solid platform
// implementations for iOS, Android, Web, and macOS but not for Linux or
// Windows desktop. The web stub defaults to `true`; the io variant uses
// `dart:io.Platform` to gate Linux + Windows.
export 'youtube_platform_support_stub.dart'
    if (dart.library.io) 'youtube_platform_support_io.dart';
