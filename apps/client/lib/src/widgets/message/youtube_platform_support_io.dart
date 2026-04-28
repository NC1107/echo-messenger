import 'dart:io' show Platform;

/// True on iOS, Android, macOS — false on Linux, Windows desktop where
/// `webview_flutter` does not have a reliable platform implementation.
final bool youtubeIframeSupported =
    Platform.isIOS || Platform.isAndroid || Platform.isMacOS;
