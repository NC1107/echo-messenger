import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _mimeImagePng = 'image/png';

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
    if (Platform.isLinux) {
      return _readLinuxClipboard();
    } else if (Platform.isWindows) {
      return _readWindowsClipboard();
    } else if (Platform.isMacOS) {
      return _readMacOSClipboard();
    } else if (Platform.isIOS) {
      return _readIOSClipboard();
    }
  } catch (e) {
    debugPrint('[Clipboard] readImageFromClipboard failed: $e');
  }
  return null;
}

bool _isWaylandSession() {
  final waylandDisplay = Platform.environment['WAYLAND_DISPLAY'];
  final xdgSessionType = Platform.environment['XDG_SESSION_TYPE'];
  return (waylandDisplay != null && waylandDisplay.isNotEmpty) ||
      xdgSessionType == 'wayland';
}

Future<ClipboardImageData?> _readLinuxClipboard() async {
  if (_isWaylandSession()) {
    return _readWaylandClipboard();
  }
  return _readX11Clipboard();
}

Future<ClipboardImageData?> _readX11Clipboard() async {
  // Check if xclip is available and clipboard has image data
  final targets = await Process.run('xclip', [
    '-selection',
    'clipboard',
    '-t',
    'TARGETS',
    '-o',
  ]);

  if (targets.exitCode != 0) {
    debugPrint('[Clipboard] xclip TARGETS failed: ${targets.stderr}');
    return null;
  }

  final targetList = (targets.stdout as String).split('\n');
  String? imageType;
  for (final t in targetList) {
    final trimmed = t.trim();
    if (trimmed == _mimeImagePng) {
      imageType = _mimeImagePng;
      break;
    } else if (trimmed.startsWith('image/')) {
      imageType = trimmed;
    }
  }

  if (imageType == null) return null;

  final result = await Process.run(
    'xclip',
    ['-selection', 'clipboard', '-t', imageType, '-o'],
    stdoutEncoding: null, // raw bytes
  );

  if (result.exitCode != 0) {
    debugPrint('[Clipboard] xclip read failed: ${result.stderr}');
    return null;
  }

  final bytes = result.stdout as List<int>;
  if (bytes.isEmpty) return null;

  final ext = imageType == _mimeImagePng ? 'png' : 'jpg';
  return ClipboardImageData(
    bytes: Uint8List.fromList(bytes),
    mimeType: imageType,
    fileName: 'clipboard_image.$ext',
  );
}

Future<ClipboardImageData?> _readWaylandClipboard() async {
  // List MIME types available on the Wayland clipboard
  final targets = await Process.run('wl-paste', ['--list-types']);
  if (targets.exitCode != 0) {
    debugPrint('[Clipboard] wl-paste --list-types failed: ${targets.stderr}');
    return null;
  }

  final targetList = (targets.stdout as String).split('\n');
  String? imageType;
  for (final t in targetList) {
    final trimmed = t.trim();
    if (trimmed == _mimeImagePng) {
      imageType = _mimeImagePng;
      break;
    } else if (trimmed.startsWith('image/')) {
      imageType = trimmed;
    }
  }

  if (imageType == null) return null;

  final result = await Process.run(
    'wl-paste',
    ['--type', imageType, '--no-newline'],
    stdoutEncoding: null, // raw bytes
  );

  if (result.exitCode != 0) {
    debugPrint('[Clipboard] wl-paste read failed: ${result.stderr}');
    return null;
  }

  final bytes = result.stdout as List<int>;
  if (bytes.isEmpty) return null;

  final ext = imageType == _mimeImagePng ? 'png' : 'jpg';
  return ClipboardImageData(
    bytes: Uint8List.fromList(bytes),
    mimeType: imageType,
    fileName: 'clipboard_image.$ext',
  );
}

Future<ClipboardImageData?> _readIOSClipboard() async {
  // The Flutter built-in Clipboard API only handles plain text.
  // Reading image data from the iOS pasteboard requires a native plugin.
  debugPrint(
    '[Clipboard] iOS image paste is not supported without a native pasteboard plugin',
  );
  return null;
}

Future<ClipboardImageData?> _readWindowsClipboard() async {
  // Use PowerShell to save clipboard image to a temp file
  final tempDir = await getTemporaryDirectory();
  final tempPath = '${tempDir.path}\\clipboard_paste.png';

  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '''
    \$img = Get-Clipboard -Format Image
    if (\$img -ne \$null) {
      \$img.Save("$tempPath", [System.Drawing.Imaging.ImageFormat]::Png)
      Write-Output "ok"
    }
    ''',
  ]);

  if (result.exitCode != 0 || !(result.stdout as String).contains('ok')) {
    return null;
  }

  final file = File(tempPath);
  if (!await file.exists()) return null;

  final bytes = await file.readAsBytes();
  await file.delete();

  if (bytes.isEmpty) return null;

  return ClipboardImageData(
    bytes: bytes,
    mimeType: _mimeImagePng,
    fileName: 'clipboard_image.png',
  );
}

Future<ClipboardImageData?> _readMacOSClipboard() async {
  // Use osascript + pngpaste or pbpaste for macOS
  final tempDir = await getTemporaryDirectory();
  final tempPath = '${tempDir.path}/clipboard_paste.png';

  // Try pngpaste first (common tool), fall back to osascript
  var result = await Process.run('pngpaste', [tempPath]);
  if (result.exitCode != 0) {
    result = await Process.run('osascript', [
      '-e',
      'set theFile to (POSIX file "$tempPath")',
      '-e',
      'try',
      '-e',
      'set theImage to the clipboard as «class PNGf»',
      '-e',
      'set fileRef to open for access theFile with write permission',
      '-e',
      'write theImage to fileRef',
      '-e',
      'close access fileRef',
      '-e',
      'on error',
      '-e',
      'return "no image"',
      '-e',
      'end try',
    ]);
  }

  final file = File(tempPath);
  if (!await file.exists()) return null;

  final bytes = await file.readAsBytes();
  await file.delete();

  if (bytes.isEmpty) return null;

  return ClipboardImageData(
    bytes: bytes,
    mimeType: _mimeImagePng,
    fileName: 'clipboard_image.png',
  );
}

/// Write image bytes to the system clipboard.
Future<bool> writeImageToClipboard(Uint8List bytes, String mimeType) async {
  try {
    if (Platform.isLinux) {
      return _writeLinuxClipboard(bytes, mimeType);
    } else if (Platform.isWindows) {
      return _writeWindowsClipboard(bytes);
    } else if (Platform.isMacOS) {
      return _writeMacOSClipboard(bytes);
    } else if (Platform.isIOS) {
      debugPrint(
        '[Clipboard] iOS image copy is not supported without a native pasteboard plugin',
      );
    }
  } catch (e) {
    debugPrint('[Clipboard] writeImageToClipboard failed: $e');
  }
  return false;
}

Future<bool> _writeLinuxClipboard(Uint8List bytes, String mimeType) async {
  if (_isWaylandSession()) {
    return _writeWaylandClipboard(bytes, mimeType);
  }
  return _writeX11Clipboard(bytes, mimeType);
}

Future<bool> _writeX11Clipboard(Uint8List bytes, String mimeType) async {
  final process = await Process.start('xclip', [
    '-selection',
    'clipboard',
    '-t',
    mimeType,
  ]);
  process.stdin.add(bytes);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    debugPrint('[Clipboard] xclip write failed with exit code $exitCode');
  }
  return exitCode == 0;
}

Future<bool> _writeWaylandClipboard(Uint8List bytes, String mimeType) async {
  final process = await Process.start('wl-copy', ['--type', mimeType]);
  process.stdin.add(bytes);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    debugPrint('[Clipboard] wl-copy write failed with exit code $exitCode');
  }
  return exitCode == 0;
}

Future<bool> _writeWindowsClipboard(Uint8List bytes) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = '${tempDir.path}\\clipboard_write.png';
  await File(tempPath).writeAsBytes(bytes);

  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '''
    Add-Type -AssemblyName System.Windows.Forms
    \$img = [System.Drawing.Image]::FromFile("$tempPath")
    [System.Windows.Forms.Clipboard]::SetImage(\$img)
    \$img.Dispose()
    Write-Output "ok"
    ''',
  ]);

  try {
    await File(tempPath).delete();
  } catch (_) {}

  return result.exitCode == 0 && (result.stdout as String).contains('ok');
}

Future<bool> _writeMacOSClipboard(Uint8List bytes) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = '${tempDir.path}/clipboard_write.png';
  await File(tempPath).writeAsBytes(bytes);

  final result = await Process.run('osascript', [
    '-e',
    'set the clipboard to (read (POSIX file "$tempPath") as «class PNGf»)',
  ]);

  try {
    await File(tempPath).delete();
  } catch (_) {}

  return result.exitCode == 0;
}
