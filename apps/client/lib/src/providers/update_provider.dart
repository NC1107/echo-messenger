import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/update_service.dart' as update_svc;
import '../version.dart';

enum UpdateStatus {
  idle,
  checking,
  downloading,
  readyToInstall,
  installing,
  error,
}

class UpdateState {
  final UpdateStatus status;
  final String? latestVersion;
  final String? downloadUrl;
  final String? assetDownloadUrl;
  final String? downloadedFilePath;
  final double downloadProgress;
  final String? errorMessage;
  final bool dismissed;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.latestVersion,
    this.downloadUrl,
    this.assetDownloadUrl,
    this.downloadedFilePath,
    this.downloadProgress = 0,
    this.errorMessage,
    this.dismissed = false,
  });

  bool get updateAvailable =>
      latestVersion != null &&
      latestVersion != appVersion &&
      _isNewer(latestVersion!, appVersion);

  /// Backward-compat: old code checks `state.checking`.
  bool get checking => status == UpdateStatus.checking;

  UpdateState copyWith({
    UpdateStatus? status,
    String? latestVersion,
    String? downloadUrl,
    String? assetDownloadUrl,
    String? downloadedFilePath,
    double? downloadProgress,
    String? errorMessage,
    bool? dismissed,
  }) {
    return UpdateState(
      status: status ?? this.status,
      latestVersion: latestVersion ?? this.latestVersion,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      assetDownloadUrl: assetDownloadUrl ?? this.assetDownloadUrl,
      downloadedFilePath: downloadedFilePath ?? this.downloadedFilePath,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      dismissed: dismissed ?? this.dismissed,
    );
  }
}

bool _isNewer(String remote, String local) {
  if (local == 'dev') return false;
  final r = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final l = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final rv = i < r.length ? r[i] : 0;
    final lv = i < l.length ? l[i] : 0;
    if (rv > lv) return true;
    if (rv < lv) return false;
  }
  return false;
}

const _cacheKey = 'update_check_cache';
const _cacheTimeKey = 'update_check_time';
const _dismissedVersionKey = 'update_dismissed_version';
const _downloadedFileKey = 'update_downloaded_file';
const _downloadedVersionKey = 'update_downloaded_version';
const _cacheTtl = Duration(hours: 24);

const _releaseApiUrl =
    'https://api.github.com/repos/NC1107/echo-messenger/releases/latest';
const _releasesPageUrl =
    'https://github.com/NC1107/echo-messenger/releases/latest';

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier() : super(const UpdateState());

  Future<void> check({bool force = false}) async {
    if (appVersion == 'dev') return;
    state = state.copyWith(status: UpdateStatus.checking);

    try {
      final prefs = await SharedPreferences.getInstance();

      if (!force) {
        final cachedTime = prefs.getInt(_cacheTimeKey) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - cachedTime;
        if (age < _cacheTtl.inMilliseconds) {
          final cached = prefs.getString(_cacheKey);
          if (cached != null) {
            final data = jsonDecode(cached) as Map<String, dynamic>;
            final version = data['version'] as String;
            final dismissed = prefs.getString(_dismissedVersionKey) == version;
            final readyPath = await _checkExistingDownload(prefs, version);

            state = UpdateState(
              latestVersion: version,
              downloadUrl: data['url'] as String?,
              assetDownloadUrl: data['assetUrl'] as String?,
              dismissed: dismissed,
              status: readyPath != null
                  ? UpdateStatus.readyToInstall
                  : UpdateStatus.idle,
              downloadedFilePath: readyPath,
            );
            return;
          }
        }
      }

      final response = await http
          .get(
            Uri.parse(_releaseApiUrl),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        state = state.copyWith(status: UpdateStatus.idle);
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final url = (data['html_url'] as String?) ?? _releasesPageUrl;

      // Find the platform-specific asset URL.
      String? assetUrl;
      final assetName = update_svc.getAssetNameForPlatform();
      if (assetName != null) {
        final assets = data['assets'] as List<dynamic>? ?? [];
        for (final asset in assets) {
          if ((asset['name'] as String?) == assetName) {
            assetUrl = asset['browser_download_url'] as String?;
            break;
          }
        }
      }

      await prefs.setString(
        _cacheKey,
        jsonEncode({'version': version, 'url': url, 'assetUrl': assetUrl}),
      );
      await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);

      final dismissed = prefs.getString(_dismissedVersionKey) == version;
      final readyPath = await _checkExistingDownload(prefs, version);

      state = UpdateState(
        latestVersion: version,
        downloadUrl: url,
        assetDownloadUrl: assetUrl,
        dismissed: dismissed,
        status: readyPath != null
            ? UpdateStatus.readyToInstall
            : UpdateStatus.idle,
        downloadedFilePath: readyPath,
      );
    } catch (_) {
      state = state.copyWith(status: UpdateStatus.idle);
    }
  }

  /// Download the update binary in the background.
  Future<void> downloadUpdate() async {
    final assetUrl = state.assetDownloadUrl;
    final assetName = update_svc.getAssetNameForPlatform();
    if (assetUrl == null || assetName == null || !update_svc.canAutoUpdate) {
      return;
    }

    state = state.copyWith(
      status: UpdateStatus.downloading,
      downloadProgress: 0,
      errorMessage: null,
    );

    try {
      final filePath = await update_svc.downloadFile(assetUrl, assetName, (
        progress,
      ) {
        if (mounted) {
          state = state.copyWith(downloadProgress: progress);
        }
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_downloadedFileKey, filePath);
      await prefs.setString(_downloadedVersionKey, state.latestVersion ?? '');

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        downloadedFilePath: filePath,
        downloadProgress: 1,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Cancel an in-progress download and reset state.
  void cancelDownload() {
    // The download runs inside update_svc.downloadFile which is a single
    // awaited future. Cancellation is best-effort: we reset state and the
    // partially downloaded file will be cleaned up on next check.
    state = state.copyWith(status: UpdateStatus.idle, downloadProgress: 0);
  }

  /// Apply the downloaded update (restart the app).
  Future<void> applyUpdate() async {
    final filePath = state.downloadedFilePath;
    if (filePath == null) return;

    state = state.copyWith(status: UpdateStatus.installing);
    try {
      await update_svc.applyUpdate(filePath);
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> dismiss() async {
    state = state.copyWith(dismissed: true);
    if (state.latestVersion != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedVersionKey, state.latestVersion!);
    }
  }

  Future<String?> _checkExistingDownload(
    SharedPreferences prefs,
    String version,
  ) async {
    if (!update_svc.canAutoUpdate) return null;
    final savedPath = prefs.getString(_downloadedFileKey);
    final savedVersion = prefs.getString(_downloadedVersionKey);
    if (savedPath != null && savedVersion == version) {
      if (await update_svc.fileExists(savedPath)) return savedPath;
      // Stale reference -- clean up.
      await prefs.remove(_downloadedFileKey);
      await prefs.remove(_downloadedVersionKey);
    }
    return null;
  }
}

final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>(
  (ref) => UpdateNotifier(),
);
