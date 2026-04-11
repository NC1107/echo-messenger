/// Per-user data directory management.
///
/// Each user gets an isolated directory under the app support path:
/// `<appSupport>/echo-messenger/users/<userId>@<host>/`
///
/// Subdirectories: `keys/`, `sessions/`, `cache/`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
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
    if (kIsWeb) return;
    final appDir = await getApplicationSupportDirectory();
    _basePath = p.join(appDir.path, 'echo-messenger');
    await Directory(_basePath!).create(recursive: true);
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

    await Directory(p.join(_currentUserPath!, 'keys')).create(recursive: true);
    await Directory(
      p.join(_currentUserPath!, 'sessions'),
    ).create(recursive: true);
    await Directory(p.join(_currentUserPath!, 'cache')).create(recursive: true);

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
    _currentUserPath = null;
    _currentUserId = null;
    _currentHost = null;
  }
}
