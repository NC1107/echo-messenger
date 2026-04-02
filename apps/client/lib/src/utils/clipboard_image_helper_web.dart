import 'dart:html' as html;
import 'dart:typed_data';

import 'clipboard_image_helper_stub.dart';

String _extensionForMime(String mimeType) {
  switch (mimeType) {
    case 'image/jpeg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    default:
      return 'png';
  }
}

Future<ClipboardImageData?> readImageFromClipboard() async {
  try {
    final clipboard = html.window.navigator.clipboard;
    if (clipboard == null) {
      return null;
    }

    final items = await clipboard.read();
    for (final item in items) {
      for (final type in item.types) {
        if (!type.startsWith('image/')) {
          continue;
        }

        final blob = await item.getType(type);
        final buffer = await blob.arrayBuffer();
        final bytes = Uint8List.view(buffer);
        final ext = _extensionForMime(type);

        return ClipboardImageData(
          bytes: bytes,
          mimeType: type,
          fileName: 'pasted-image.$ext',
        );
      }
    }
  } catch (_) {
    return null;
  }

  return null;
}
