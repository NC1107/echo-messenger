import 'package:echo_app/src/services/secure_key_store.dart';

/// In-memory [SecureKeyStore] for testing without platform storage.
class FakeSecureKeyStore extends SecureKeyStore {
  final Map<String, String> _store = {};

  FakeSecureKeyStore() : super.forTesting();

  @override
  Future<String?> read(String key) async => _store[key];

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

  /// Dump all keys for debugging.
  Map<String, String> get dump => Map.unmodifiable(_store);
}
