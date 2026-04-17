/// Secure key storage wrapper around [FlutterSecureStorage].
///
/// Provides read/write/delete/list operations for cryptographic keys using
/// platform-specific secure storage (Keychain on macOS/iOS, Keystore on Android,
/// libsecret on Linux, DPAPI on Windows, encrypted localStorage on web).
///
/// Replaces direct SharedPreferences usage for sensitive crypto material.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../utils/debug_log.dart';

class SecureKeyStore {
  /// Singleton instance.
  static SecureKeyStore? _instance;

  final FlutterSecureStorage _storage;

  /// User-scoped key prefix. Empty = global (pre-login).
  String _userPrefix = '';

  /// Scope all storage operations to a specific user.
  void setUserScope(String userId, String serverHost) {
    _userPrefix = 'u/$userId@$serverHost/';
    debugLog('setUserScope: prefix=$_userPrefix', 'SecureKeyStore');
  }

  /// Clear user scope (on logout).
  void clearUserScope() {
    debugLog('clearUserScope (was: $_userPrefix)', 'SecureKeyStore');
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
        mOptions: MacOsOptions(useDataProtectionKeyChain: true),
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
      debugLog('read($key) failed: $e', 'SecureKeyStore');
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
      debugLog('write($key) failed: $e', 'SecureKeyStore');
      rethrow;
    }
  }

  /// Delete a single key.
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: '$_userPrefix$key');
    } catch (e) {
      debugLog('delete($key) failed: $e', 'SecureKeyStore');
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
      debugLog('readAll failed: $e', 'SecureKeyStore');
      return {};
    }
  }

  /// Check if a key exists.
  Future<bool> containsKey(String key) async {
    try {
      return await _storage.containsKey(key: '$_userPrefix$key');
    } catch (e) {
      debugLog('containsKey($key) failed: $e', 'SecureKeyStore');
      return false;
    }
  }

  // -- Global-scope methods (no user prefix) --
  //
  // Used for pre-login data such as auth tokens that must be persisted
  // before user scope is established (e.g. after server-side token
  // rotation but before _setUserScope completes).

  /// Read a global (non-user-scoped) value by key.
  ///
  /// Throws on backend failure so callers can distinguish "not found" (null)
  /// from "storage unavailable".
  Future<String?> readGlobal(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugLog('readGlobal($key) failed: $e', 'SecureKeyStore');
      rethrow;
    }
  }

  /// Write a global (non-user-scoped) key-value pair.
  ///
  /// Throws on backend failure so callers can fall back to less-secure
  /// storage rather than silently losing the value.
  Future<void> writeGlobal(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugLog('writeGlobal($key) failed: $e', 'SecureKeyStore');
      rethrow;
    }
  }

  /// Return a 32-byte AES key for Hive box encryption, creating one if it
  /// does not already exist.  The key is persisted in platform-secure storage
  /// (global scope) so it survives app restarts and user re-logins.
  Future<List<int>> getOrCreateHiveCacheKey() async {
    const keyName = 'hive_message_cache_key';
    final existing = await readGlobal(keyName);
    if (existing != null && existing.isNotEmpty) {
      return base64.decode(existing);
    }
    final newKey = Hive.generateSecureKey();
    await writeGlobal(keyName, base64.encode(newKey));
    return newKey;
  }

  /// Delete a global (non-user-scoped) key. Swallows errors.
  Future<void> deleteGlobal(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugLog('deleteGlobal($key) failed: $e', 'SecureKeyStore');
    }
  }
}
