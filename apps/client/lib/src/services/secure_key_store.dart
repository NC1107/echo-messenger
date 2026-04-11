/// Secure key storage wrapper around [FlutterSecureStorage].
///
/// Provides read/write/delete/list operations for cryptographic keys using
/// platform-specific secure storage (Keychain on macOS/iOS, Keystore on Android,
/// libsecret on Linux, DPAPI on Windows, encrypted localStorage on web).
///
/// Replaces direct SharedPreferences usage for sensitive crypto material.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureKeyStore {
  /// Singleton instance.
  static SecureKeyStore? _instance;

  final FlutterSecureStorage _storage;

  /// User-scoped key prefix. Empty = global (pre-login).
  String _userPrefix = '';

  /// Scope all storage operations to a specific user.
  void setUserScope(String userId, String serverHost) {
    _userPrefix = 'u/$userId@$serverHost/';
    debugPrint('[SecureKeyStore] setUserScope: prefix=$_userPrefix');
  }

  /// Clear user scope (on logout).
  void clearUserScope() {
    debugPrint('[SecureKeyStore] clearUserScope (was: $_userPrefix)');
    _userPrefix = '';
  }

  /// Current prefix for testing visibility.
  @visibleForTesting
  String get keyPrefix => _userPrefix;

  /// Delete all keys belonging to the current user scope.
  Future<void> deleteAllForUser() async {
    if (_userPrefix.isEmpty) return;
    final all = await _storage.readAll();
    for (final key in all.keys) {
      if (key.startsWith(_userPrefix)) {
        await _storage.delete(key: key);
      }
    }
  }

  SecureKeyStore._()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        lOptions: LinuxOptions(),
        wOptions: WindowsOptions(),
        webOptions: WebOptions(),
      );

  /// Protected constructor for test subclasses.
  @visibleForTesting
  SecureKeyStore.forTesting() : _storage = const FlutterSecureStorage();

  /// Returns the shared [SecureKeyStore] instance.
  static SecureKeyStore get instance {
    _instance ??= SecureKeyStore._();
    return _instance!;
  }

  /// Overwrite the singleton for testing purposes.
  @visibleForTesting
  static set instance(SecureKeyStore store) {
    _instance = store;
  }

  /// Read a value by key. Returns null if not found.
  ///
  /// Throws if the underlying storage backend fails (e.g. keyring locked on
  /// Linux).  Callers that rely on stored keys — most importantly [init()] —
  /// must propagate the exception so that [initAndUploadKeys()] can surface it
  /// to the user instead of silently regenerating new identity keys.
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: '$_userPrefix$key');
    } catch (e) {
      debugPrint('[SecureKeyStore] read($key) failed: $e');
      rethrow;
    }
  }

  /// Write a key-value pair.
  ///
  /// Throws if the underlying storage backend fails so that callers can avoid
  /// treating the operation as a success (e.g. the migration helper should not
  /// remove the SharedPreferences entry if this write fails).
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: '$_userPrefix$key', value: value);
    } catch (e) {
      debugPrint('[SecureKeyStore] write($key) failed: $e');
      rethrow;
    }
  }

  /// Delete a single key.
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: '$_userPrefix$key');
    } catch (e) {
      debugPrint('[SecureKeyStore] delete($key) failed: $e');
    }
  }

  /// Read all key-value pairs for the current user scope.
  Future<Map<String, String>> readAll() async {
    try {
      final all = await _storage.readAll();
      if (_userPrefix.isEmpty) return all;
      return Map.fromEntries(
        all.entries
            .where((e) => e.key.startsWith(_userPrefix))
            .map((e) => MapEntry(e.key.substring(_userPrefix.length), e.value)),
      );
    } catch (e) {
      debugPrint('[SecureKeyStore] readAll failed: $e');
      return {};
    }
  }

  /// Check if a key exists.
  Future<bool> containsKey(String key) async {
    try {
      return await _storage.containsKey(key: '$_userPrefix$key');
    } catch (e) {
      debugPrint('[SecureKeyStore] containsKey($key) failed: $e');
      return false;
    }
  }
}
