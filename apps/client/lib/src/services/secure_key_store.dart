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
      return await _storage.read(key: key);
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
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('[SecureKeyStore] write($key) failed: $e');
      rethrow;
    }
  }

  /// Delete a single key.
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('[SecureKeyStore] delete($key) failed: $e');
    }
  }

  /// Read all key-value pairs. Used for iterating session keys.
  Future<Map<String, String>> readAll() async {
    try {
      return await _storage.readAll();
    } catch (e) {
      debugPrint('[SecureKeyStore] readAll failed: $e');
      return {};
    }
  }

  /// Check if a key exists.
  Future<bool> containsKey(String key) async {
    try {
      return await _storage.containsKey(key: key);
    } catch (e) {
      debugPrint('[SecureKeyStore] containsKey($key) failed: $e');
      return false;
    }
  }
}
