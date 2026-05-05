/// Pure helpers for building the `[img:URL]` / `[video:URL]` / `[audio:URL]`
/// / `[file:URL]` markers the chat-render pipeline understands, plus a
/// MIME → extension fallback used when the picker hands over bytes without
/// a usable filename.
///
/// Pulled out of `chat_input_bar.dart` (~50 LoC) so the marker format is
/// reusable from paste / drop / gif-picker code paths without dragging the
/// 2071-line state class into scope.
library;

const String kImageGifMimeType = 'image/gif';

const _imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp'};
const _videoExts = {'mp4', 'webm', 'mov'};
const _audioExts = {'mp3', 'ogg', 'wav', 'm4a', 'aac'};

/// Build the marker string for a media attachment.
///
/// `extension` is matched case-insensitively against the image / video /
/// audio sets; anything else falls back to `[file:URL]` so the receiver
/// renders a generic-file affordance.
String buildMediaMarker({required String extension, required String url}) {
  final ext = extension.toLowerCase();
  if (_imageExts.contains(ext)) return '[img:$url]';
  if (_videoExts.contains(ext)) return '[video:$url]';
  if (_audioExts.contains(ext)) return '[audio:$url]';
  return '[file:$url]';
}

/// Best-effort MIME → file-extension lookup for the few types Echo
/// recognizes natively. Unknown MIMEs return `'bin'` so the marker still
/// produces a useful `[file:URL]` rather than a broken inline preview.
String extensionFromMime(String mimeType) {
  switch (mimeType.toLowerCase()) {
    case 'image/jpeg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case kImageGifMimeType:
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'video/mp4':
      return 'mp4';
    case 'video/webm':
      return 'webm';
    case 'video/quicktime':
      return 'mov';
    case 'application/pdf':
      return 'pdf';
    default:
      return 'bin';
  }
}
