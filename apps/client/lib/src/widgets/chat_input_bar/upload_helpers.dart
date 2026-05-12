/// Constants and pure-Dart helpers shared by the file picker, image picker,
/// camera picker, and clipboard-paste paths in `chat_input_bar.dart`.
///
/// Extracted so the three picker methods don't each redeclare their own
/// copies, and so other widgets (e.g. avatar pickers, settings file pickers)
/// can reuse the same caps and formatting without depending on the chat
/// input bar's internals.
library;

/// Default MIME subtype when we can't infer the file type.
const kOctetStream = 'octet-stream';

/// Extension → `[type, subtype]` map used by every attachment path
/// (file picker, image picker, camera, clipboard paste, drag-and-drop).
/// Unknown extensions fall back to `['application', kOctetStream]`.
const kMimeTypes = <String, List<String>>{
  'jpg': ['image', 'jpeg'],
  'jpeg': ['image', 'jpeg'],
  'png': ['image', 'png'],
  'gif': ['image', 'gif'],
  'webp': ['image', 'webp'],
  'mp4': ['video', 'mp4'],
  'mov': ['video', 'quicktime'],
  'webm': ['video', 'webm'],
  'pdf': ['application', 'pdf'],
  'mp3': ['audio', 'mpeg'],
  'ogg': ['audio', 'ogg'],
  'wav': ['audio', 'wav'],
  'm4a': ['audio', 'mp4'],
  'aac': ['audio', 'aac'],
};

/// Mirror of `MAX_FILE_SIZE` in `apps/server/src/routes/media.rs`. Both must
/// be bumped together. Cloudflare Free also caps request bodies at 100 MB,
/// so going higher than this without proxy work will 502 on prod.
const kMaxUploadBytes = 100 * 1024 * 1024;

/// Strip the original name and return `media.{ext}` (or just `media` if the
/// filename had no extension). Used by the "preserve original filenames"
/// privacy toggle.
String genericFilename(String original) {
  final dot = original.lastIndexOf('.');
  if (dot <= 0 || dot == original.length - 1) return 'media';
  final ext = original.substring(dot + 1).toLowerCase();
  return 'media.$ext';
}

/// Format a byte count as a human-readable string (1024-based, 1 decimal).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}
