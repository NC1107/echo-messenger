import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

bool get canAutoUpdate => Platform.isLinux || Platform.isWindows;

String? getAssetNameForPlatform() {
  if (Platform.isLinux) return 'Echo-x86_64.AppImage';
  if (Platform.isWindows) return 'Echo-Setup-x64.exe';
  return null;
}

Future<String> getUpdateDirectory() async {
  final appSupport = await getApplicationSupportDirectory();
  final updateDir = Directory('${appSupport.path}/updates');
  if (!await updateDir.exists()) {
    await updateDir.create(recursive: true);
  }
  return updateDir.path;
}

Future<String> downloadFile(
  String url,
  String fileName,
  void Function(double progress) onProgress,
) async {
  final updateDir = await getUpdateDirectory();
  final filePath = '$updateDir/$fileName';
  final markerPath = '$filePath.downloading';

  // Create marker
  await File(markerPath).writeAsString('downloading');

  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);

    if (response.statusCode != 200) {
      throw Exception('Download failed (${response.statusCode})');
    }

    final contentLength = response.contentLength ?? 0;
    final sink = File(filePath).openWrite();
    var received = 0;

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (contentLength > 0) {
        onProgress(received / contentLength);
      }
    }

    await sink.flush();
    await sink.close();
  } finally {
    client.close();
  }

  // Remove marker
  final marker = File(markerPath);
  if (await marker.exists()) await marker.delete();

  return filePath;
}

Future<void> applyUpdate(String downloadedFilePath) async {
  if (Platform.isLinux) {
    await _applyLinux(downloadedFilePath);
  } else if (Platform.isWindows) {
    await _applyWindows(downloadedFilePath);
  }
}

Future<void> _applyLinux(String downloadedFilePath) async {
  final appImagePath = Platform.environment['APPIMAGE'];
  if (appImagePath == null || appImagePath.isEmpty) {
    throw UnsupportedError(
      'Not running as AppImage. Install manually from: $downloadedFilePath',
    );
  }

  final currentFile = File(appImagePath);
  final backupPath = '$appImagePath.bak';

  if (await currentFile.exists()) {
    await currentFile.rename(backupPath);
  }

  await File(downloadedFilePath).copy(appImagePath);
  await File(downloadedFilePath).delete();
  await Process.run('chmod', ['+x', appImagePath]);

  await Process.start(appImagePath, [], mode: ProcessStartMode.detached);
  exit(0);
}

Future<void> _applyWindows(String downloadedFilePath) async {
  await Process.start(downloadedFilePath, [
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
  ], mode: ProcessStartMode.detached);
  exit(0);
}

Future<bool> fileExists(String path) => File(path).exists();

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}
