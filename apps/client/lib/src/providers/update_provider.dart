import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/update_service.dart' as update_svc;
import '../version.dart';

part 'update_provider.g.dart';

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

  /// Markdown body of the latest release's notes, as returned by the
  /// GitHub releases API.  Cached locally; null until the first check
  /// completes.  Consumed by [WhatsNewModal] (via [releaseNotesProvider])
  /// to render the "What's New" sheet on first launch after an update.
  final String? releaseBody;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.latestVersion,
    this.downloadUrl,
    this.assetDownloadUrl,
    this.downloadedFilePath,
    this.downloadProgress = 0,
    this.errorMessage,
    this.dismissed = false,
    this.releaseBody,
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
    String? releaseBody,
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
      releaseBody: releaseBody ?? this.releaseBody,
    );
  }
}

/// Strip auto-generated noise from a GitHub release notes body so the
/// What's-New modal shows a clean changelog.  Trims:
///
///   - The `**Full Changelog**: https://...compare/vA...vB` trailer that
///     `softprops/action-gh-release` always appends.
///   - Dependabot's `bumps `dep` from X to Y` diff URLs (one per line) —
///     the human commit subject above them is what readers actually
///     want.
///   - `Co-Authored-By:` trailers from squash commits.
///   - Leading/trailing whitespace.
///
/// Pure function — exposed for unit tests.
String? sanitizeReleaseBody(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var body = raw;

  // GitHub's auto-changelog footer: "**Full Changelog**: <url>"
  body = body.replaceAll(
    RegExp(
      r'\*\*Full Changelog\*\*:\s*https://github\.com/\S+',
      multiLine: true,
    ),
    '',
  );

  // Dependabot dependency diff URLs.
  body = body.replaceAll(
    RegExp(
      r'^- \[.*\]\(https://github\.com/\S+/compare/\S+\)$',
      multiLine: true,
    ),
    '',
  );

  // Co-author trailers from squashed PRs.
  body = body.replaceAll(
    RegExp(r'^Co-Authored-By:.*$', multiLine: true, caseSensitive: false),
    '',
  );

  // Collapse 3+ blank lines into a single blank line.
  body = body.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  body = body.trim();
  return body.isEmpty ? null : body;
}

/// Monotonic build counter from a dev version like `0.0.0-dev.42`, or null
/// if [v] isn't a dev-channel version.
int? _devBuildNumber(String v) {
  final m = RegExp(r'-dev\.(\d+)$').firstMatch(v);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// True when the dev channel is active for this build, i.e. `APP_VERSION` is a
/// `0.0.0-dev.<n>` rolling build. The bare legacy `'dev'` is NOT a channel —
/// it has no comparable build number, so updates stay disabled for it.
bool get _isDevChannel => _devBuildNumber(appVersion) != null;

bool _isNewer(String remote, String local) {
  // Dev channel: compare the monotonic `-dev.<n>` counter, since the semver
  // triple is always 0.0.0 for dev builds.
  final localDev = _devBuildNumber(local);
  if (localDev != null) {
    final remoteDev = _devBuildNumber(remote);
    return remoteDev != null && remoteDev > localDev;
  }
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

/// Test-only view of the pure version comparison (handles both the stable
/// semver triple and the dev channel's `-dev.<n>` counter).
@visibleForTesting
bool isNewerVersion(String remote, String local) => _isNewer(remote, local);

const _cacheKey = 'update_check_cache';
const _cacheTimeKey = 'update_check_time';
const _dismissedVersionKey = 'update_dismissed_version';
const _downloadedFileKey = 'update_downloaded_file';
const _downloadedVersionKey = 'update_downloaded_version';

/// How long an update-check result is reused before re-fetching from the
/// GitHub releases API. Previously 24h, which meant a release landing a few
/// hours after the user's first launch of the day was suppressed until the
/// next day (#793). One hour balances API politeness against freshness for
/// users who keep the app open all day.
const _cacheTtl = Duration(hours: 1);

const _releaseApiUrl =
    'https://api.github.com/repos/NC1107/echo-messenger/releases/latest';
const _releasesPageUrl =
    'https://github.com/NC1107/echo-messenger/releases/latest';

/// Dev channel endpoints. `dev-build.yml` keeps a single rolling pre-release
/// tagged `dev-latest` whose title carries the `0.0.0-dev.<n>` version and
/// whose asset is the latest dev AppImage. `/releases/latest` deliberately
/// excludes pre-releases, so stable builds never see this.
const _devReleaseApiUrl =
    'https://api.github.com/repos/NC1107/echo-messenger/releases/tags/dev-latest';
const _devReleasesPageUrl =
    'https://github.com/NC1107/echo-messenger/releases/tag/dev-latest';

@Riverpod(keepAlive: true)
class Update extends _$Update {
  /// True after the provider has been disposed; guards async-progress
  /// callbacks from setting state on a dead notifier (the StateNotifier
  /// `mounted` flag has no equivalent on Notifier, so we track it manually).
  bool _disposed = false;

  /// Background timer that re-checks GitHub for new releases while the app
  /// is open. Without this, long-lived sessions (e.g. desktop users who
  /// leave the app running) never learn about updates until they restart.
  /// The 30-minute interval pairs with the 1h cache TTL so worst-case
  /// GitHub-hit rate is once per hour. See [_cacheTtl].
  Timer? _periodicTimer;

  @override
  UpdateState build() {
    _periodicTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      // best-effort silent re-check; honors the same 1h cache TTL so two
      // ticks within an hour won't both hit GitHub
      check(force: false);
    });
    ref.onDispose(() {
      _periodicTimer?.cancel();
      _disposed = true;
    });
    return const UpdateState();
  }

  Future<void> check({bool force = false}) async {
    // The bare legacy 'dev' build has no comparable version → no channel.
    // A `0.0.0-dev.<n>` build rides the dev channel (see [_isDevChannel]).
    if (appVersion == 'dev') {
      debugPrint('[UpdateProvider] check skipped — untagged dev build');
      return;
    }
    state = state.copyWith(status: UpdateStatus.checking);

    try {
      final prefs = await SharedPreferences.getInstance();

      if (!force) {
        final usedCache = await _tryLoadFromCache(prefs);
        if (usedCache) {
          debugPrint(
            '[UpdateProvider] check served from cache (TTL ${_cacheTtl.inMinutes}m)',
          );
          return;
        }
      }

      debugPrint(
        '[UpdateProvider] check fetching from GitHub releases (force=$force)',
      );
      await _fetchLatestRelease(prefs);
    } catch (e) {
      debugPrint('[UpdateProvider] Error checking for updates: $e');
      state = state.copyWith(status: UpdateStatus.idle);
    }
  }

  /// Attempt to load update info from the local cache.
  /// Returns true if cache was valid and state was set, false otherwise.
  Future<bool> _tryLoadFromCache(SharedPreferences prefs) async {
    final cachedTime = prefs.getInt(_cacheTimeKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - cachedTime;
    if (age >= _cacheTtl.inMilliseconds) return false;

    final cached = prefs.getString(_cacheKey);
    if (cached == null) return false;

    final data = jsonDecode(cached) as Map<String, dynamic>;
    final version = data['version'] as String;
    final dismissed = prefs.getString(_dismissedVersionKey) == version;
    final readyPath = await _checkExistingDownload(prefs, version);

    state = UpdateState(
      latestVersion: version,
      downloadUrl: data['url'] as String?,
      assetDownloadUrl: data['assetUrl'] as String?,
      releaseBody: data['body'] as String?,
      dismissed: dismissed,
      status: readyPath != null
          ? UpdateStatus.readyToInstall
          : UpdateStatus.idle,
      downloadedFilePath: readyPath,
    );
    return true;
  }

  /// Fetch the latest release from GitHub and update state + cache.
  ///
  /// Dev-channel builds read the rolling `dev-latest` pre-release; stable
  /// builds read `/releases/latest` (which excludes pre-releases).
  Future<void> _fetchLatestRelease(SharedPreferences prefs) async {
    final isDev = _isDevChannel;
    final response = await http
        .get(
          Uri.parse(isDev ? _devReleaseApiUrl : _releaseApiUrl),
          headers: {'Accept': 'application/vnd.github.v3+json'},
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      state = state.copyWith(status: UpdateStatus.idle);
      return;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final String version;
    if (isDev) {
      // The dev-latest tag is constant; the rolling version lives in the
      // release title (e.g. "0.0.0-dev.42").
      version = ((data['name'] as String?) ?? '').trim();
    } else {
      final tagName = (data['tag_name'] as String?) ?? '';
      version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    }
    final url =
        (data['html_url'] as String?) ??
        (isDev ? _devReleasesPageUrl : _releasesPageUrl);
    final assetUrl = _findPlatformAssetUrl(data);
    final body = sanitizeReleaseBody(data['body'] as String?);

    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'version': version,
        'url': url,
        'assetUrl': assetUrl,
        'body': body,
      }),
    );
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);

    final dismissed = prefs.getString(_dismissedVersionKey) == version;
    final readyPath = await _checkExistingDownload(prefs, version);

    state = UpdateState(
      latestVersion: version,
      downloadUrl: url,
      assetDownloadUrl: assetUrl,
      releaseBody: body,
      dismissed: dismissed,
      status: readyPath != null
          ? UpdateStatus.readyToInstall
          : UpdateStatus.idle,
      downloadedFilePath: readyPath,
    );
  }

  /// Find the platform-specific asset download URL from release data.
  String? _findPlatformAssetUrl(Map<String, dynamic> data) {
    final assetName = update_svc.getAssetNameForPlatform();
    if (assetName == null) return null;

    final assets = data['assets'] as List<dynamic>? ?? [];
    for (final asset in assets) {
      if ((asset['name'] as String?) == assetName) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
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
        if (!_disposed) {
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
