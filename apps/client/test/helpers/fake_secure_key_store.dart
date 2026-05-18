import 'package:flutter/services.dart' show PlatformException;
import 'package:echo_app/src/services/secure_key_store.dart';

/// In-memory [SecureKeyStore] for testing without platform storage.
///
/// Pre-loaded keys → `read` returns the value.
/// Missing keys → `read` returns null.
/// Keys whose name appears in [throwOnRead] → `read` throws the configured
/// exception (use for simulating "keyring locked" failure modes — audit P0-1).
class FakeSecureKeyStore extends SecureKeyStore {
  final Map<String, String> _store = {};

  /// Map from key name → exception that `read`/`readGlobal` should throw
  /// instead of returning a value. Lets tests simulate a libsecret-locked
  /// or Keychain-denied environment without needing platform plugins.
  final Map<String, Exception> throwOnRead = {};

  FakeSecureKeyStore() : super.forTesting();

  @override
  Future<String?> read(String key) async {
    if (throwOnRead.containsKey(key)) {
      // Mirror the wrapping behaviour of the real SecureKeyStore.read: a
      // PlatformException from the backend gets re-thrown as a typed
      // StorageUnavailableException so callers can distinguish "no key"
      // (returns null) from "storage broken" (throws). Other exception
      // types pass through verbatim (used by tests asserting that
      // non-platform errors bubble up unchanged).
      final ex = throwOnRead[key]!;
      if (ex is PlatformException) {
        throw StorageUnavailableException('read($key)', ex);
      }
      throw ex;
    }
    return _store[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.from(_store);

  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);

  // -- Global-scope overrides (same flat map, no prefix) --

  @override
  Future<String?> readGlobal(String key) async {
    if (throwOnRead.containsKey(key)) {
      final ex = throwOnRead[key]!;
      if (ex is PlatformException) {
        throw StorageUnavailableException('readGlobal($key)', ex);
      }
      throw ex;
    }
    return _store[key];
  }

  @override
  Future<void> writeGlobal(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> deleteGlobal(String key) async {
    _store.remove(key);
  }

  /// Dump all keys for debugging.
  Map<String, String> get dump => Map.unmodifiable(_store);
}
