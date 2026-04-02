/// Web / fallback stub -- auto-update not supported.
bool get canAutoUpdate => false;

String? getAssetNameForPlatform() => null;

Future<String> getUpdateDirectory() =>
    throw UnsupportedError('Auto-update not available on this platform');

Future<void> applyUpdate(String downloadedFilePath) async {}

/// Download a file from [url] to the update directory, reporting progress.
/// Returns the path of the downloaded file.
Future<String> downloadFile(
  String url,
  String fileName,
  void Function(double progress) onProgress,
) => throw UnsupportedError('Auto-update not available on this platform');

/// Check if a file exists at [path].
Future<bool> fileExists(String path) async => false;

/// Delete a file at [path] if it exists.
Future<void> deleteFile(String path) async {}
