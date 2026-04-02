import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';

class UpdateState {
  final String? latestVersion;
  final String? downloadUrl;
  final bool checking;
  final bool dismissed;

  const UpdateState({
    this.latestVersion,
    this.downloadUrl,
    this.checking = false,
    this.dismissed = false,
  });

  bool get updateAvailable =>
      latestVersion != null &&
      latestVersion != appVersion &&
      _isNewer(latestVersion!, appVersion);

  UpdateState copyWith({
    String? latestVersion,
    String? downloadUrl,
    bool? checking,
    bool? dismissed,
  }) {
    return UpdateState(
      latestVersion: latestVersion ?? this.latestVersion,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      checking: checking ?? this.checking,
      dismissed: dismissed ?? this.dismissed,
    );
  }
}

/// Compare two semver strings (e.g. "0.0.33" > "0.0.32").
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
const _cacheTtl = Duration(hours: 24);

const _releaseApiUrl =
    'https://api.github.com/repos/NC1107/echo-messenger/releases/latest';
const _releasesPageUrl =
    'https://github.com/NC1107/echo-messenger/releases/latest';

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier() : super(const UpdateState());

  Future<void> check({bool force = false}) async {
    if (appVersion == 'dev') return;
    state = state.copyWith(checking: true);

    try {
      final prefs = await SharedPreferences.getInstance();

      // Check cache unless forced
      if (!force) {
        final cachedTime = prefs.getInt(_cacheTimeKey) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - cachedTime;
        if (age < _cacheTtl.inMilliseconds) {
          final cached = prefs.getString(_cacheKey);
          if (cached != null) {
            final data = jsonDecode(cached) as Map<String, dynamic>;
            final version = data['version'] as String;
            final dismissed = prefs.getString(_dismissedVersionKey) == version;
            state = UpdateState(
              latestVersion: version,
              downloadUrl: data['url'] as String?,
              dismissed: dismissed,
            );
            return;
          }
        }
      }

      final response = await http.get(
        Uri.parse(_releaseApiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        state = state.copyWith(checking: false);
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final url = (data['html_url'] as String?) ?? _releasesPageUrl;

      // Cache the result
      await prefs.setString(
        _cacheKey,
        jsonEncode({'version': version, 'url': url}),
      );
      await prefs.setInt(
        _cacheTimeKey,
        DateTime.now().millisecondsSinceEpoch,
      );

      final dismissed = prefs.getString(_dismissedVersionKey) == version;
      state = UpdateState(
        latestVersion: version,
        downloadUrl: url,
        dismissed: dismissed,
      );
    } catch (_) {
      state = state.copyWith(checking: false);
    }
  }

  Future<void> dismiss() async {
    state = state.copyWith(dismissed: true);
    if (state.latestVersion != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedVersionKey, state.latestVersion!);
    }
  }
}

final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>(
  (ref) => UpdateNotifier(),
);
