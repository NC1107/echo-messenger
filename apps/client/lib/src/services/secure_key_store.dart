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
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('[SecureKeyStore] read($key) failed: $e');
      return null;
    }
  }

  /// Write a key-value pair.
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  /// Delete a single key.
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  /// Read all key-value pairs. Used for iterating session keys.
  Future<Map<String, String>> readAll() async {
    return await _storage.readAll();
  }

  /// Check if a key exists.
  Future<bool> containsKey(String key) async {
    return await _storage.containsKey(key: key);
  }
}
