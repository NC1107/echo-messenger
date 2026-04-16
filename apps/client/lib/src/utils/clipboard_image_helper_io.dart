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
    }
  } catch (_) {}
  return null;
}

Future<ClipboardImageData?> _readLinuxClipboard() async {
  // Check if xclip is available and clipboard has image data
  final targets = await Process.run('xclip', [
    '-selection',
    'clipboard',
    '-t',
    'TARGETS',
    '-o',
  ]);

  if (targets.exitCode != 0) return null;

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

  if (result.exitCode != 0) return null;

  final bytes = result.stdout as List<int>;
  if (bytes.isEmpty) return null;

  final ext = imageType == _mimeImagePng ? 'png' : 'jpg';
  return ClipboardImageData(
    bytes: Uint8List.fromList(bytes),
    mimeType: imageType,
    fileName: 'clipboard_image.$ext',
  );
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
    }
  } catch (e) {
    debugPrint('[Clipboard] writeImageToClipboard failed: $e');
  }
  return false;
}

Future<bool> _writeLinuxClipboard(Uint8List bytes, String mimeType) async {
  final process = await Process.start('xclip', [
    '-selection',
    'clipboard',
    '-t',
    mimeType,
  ]);
  process.stdin.add(bytes);
  await process.stdin.close();
  final exitCode = await process.exitCode;
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
