import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class ClipboardImageData {
  final Uint8List bytes;
  final String mimeType;
  final String fileName;

  const ClipboardImageData({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });
}

Future<ClipboardImageData?> readImageFromClipboard() async {
  try {
    final clipboard = web.window.navigator.clipboard;
    final items = await clipboard.read().toDart;

    for (var i = 0; i < items.length; i++) {
      final item = items.toDart[i];
      final types = item.types.toDart;

      for (final type in types) {
        final mimeType = type.toDart;
        if (mimeType.startsWith('image/')) {
          final blob = await item.getType(mimeType).toDart;
          final arrayBuffer = await blob.arrayBuffer().toDart;
          final bytes = arrayBuffer.toDart.asUint8List();

          final ext = switch (mimeType) {
            'image/png' => 'png',
            'image/jpeg' => 'jpg',
            'image/gif' => 'gif',
            'image/webp' => 'webp',
            _ => 'png',
          };

          return ClipboardImageData(
            bytes: bytes,
            mimeType: mimeType,
            fileName: 'clipboard_image.$ext',
          );
        }
      }
    }
  } catch (_) {
    // Clipboard API not available or permission denied
  }
  return null;
}
