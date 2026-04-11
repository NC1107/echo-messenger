/// Per-user data directory management.
///
/// Each user gets an isolated directory under the app support path:
/// `<appSupport>/echo-messenger/users/<userId>@<host>/`
///
/// Subdirectories: `keys/`, `sessions/`, `cache/`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class UserDataDir {
  static UserDataDir? _instance;
  String? _basePath;
  String? _currentUserPath;
  String? _currentUserId;
  String? _currentHost;

  static UserDataDir get instance => _instance ??= UserDataDir._();
  UserDataDir._();

  /// Initialize with the platform app support directory.
  /// Call once at startup (after Hive.initFlutter, before login).
  Future<void> init() async {
    if (kIsWeb) {
      debugPrint('[UserDataDir] Web platform — skipping filesystem init');
      return;
    }
    final appDir = await getApplicationSupportDirectory();
    _basePath = p.join(appDir.path, 'echo-messenger');
    await Directory(_basePath!).create(recursive: true);

    final exists = await Directory(_basePath!).exists();
    debugPrint('[UserDataDir] init: base=$_basePath exists=$exists');
    if (!exists) {
      debugPrint('[UserDataDir] ERROR: base directory creation failed!');
    }
  }

  /// Set the active user. Creates the user directory if needed.
  /// Call after login, before crypto init.
  Future<String> setUser(String userId, String serverUrl) async {
    final host = Uri.parse(serverUrl).host;
    _currentUserId = userId;
    _currentHost = host;

    if (kIsWeb) return '';

    final sanitized = '$userId@$host'.replaceAll(RegExp(r'[^\w@.\-]'), '_');
    _currentUserPath = p.join(_basePath!, 'users', sanitized);
    debugPrint('[UserDataDir] setUser: $sanitized → $_currentUserPath');

    final subdirs = ['keys', 'sessions', 'cache'];
    for (final sub in subdirs) {
      final dir = Directory(p.join(_currentUserPath!, sub));
      final existed = await dir.exists();
      await dir.create(recursive: true);
      final nowExists = await dir.exists();
      debugPrint('[UserDataDir]   $sub/ existed=$existed created=$nowExists');
      if (!nowExists) {
        debugPrint('[UserDataDir] ERROR: failed to create $sub/ directory!');
      }
    }

    return _currentUserPath!;
  }

  String get path =>
      _currentUserPath ?? (throw StateError('No user directory set'));
  String get keysPath => p.join(path, 'keys');
  String get sessionsPath => p.join(path, 'sessions');
  String get cachePath => p.join(path, 'cache');

  String? get currentUserId => _currentUserId;
  String? get currentHost => _currentHost;
  bool get isSet => _currentUserId != null;

  /// Clear current user reference (on logout). Does NOT delete files.
  void clearUser() {
    debugPrint('[UserDataDir] clearUser: $_currentUserId@$_currentHost');
    _currentUserPath = null;
    _currentUserId = null;
    _currentHost = null;
  }
}
