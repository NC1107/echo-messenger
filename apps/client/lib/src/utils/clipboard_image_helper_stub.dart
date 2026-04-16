import 'dart:typed_data';

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
  return null;
}

Future<bool> writeImageToClipboard(Uint8List bytes, String mimeType) async {
  return false;
}
