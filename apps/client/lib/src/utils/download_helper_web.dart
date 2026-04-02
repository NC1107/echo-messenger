import 'dart:convert';

import 'package:web/web.dart' as web;

Future<bool> saveBytesAsFile({
  required String fileName,
  required List<int> bytes,
  required String mimeType,
}) async {
  try {
    final safeName = fileName.isEmpty ? 'download.bin' : fileName;
    final dataUri = 'data:$mimeType;base64,${base64Encode(bytes)}';

    final anchor = web.HTMLAnchorElement()
      ..href = dataUri
      ..download = safeName
      ..style.display = 'none';

    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } catch (_) {
    return false;
  }
}
