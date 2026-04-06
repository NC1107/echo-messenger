/// AES-256-GCM group encryption service.
///
/// Each group conversation has a symmetric key that all members share.
/// Messages are encrypted with a random 12-byte nonce; the wire format is
/// `nonce(12) || ciphertext || tag(16)`, base64-encoded for transport.
///
/// Keys are cached in [SecureKeyStore] keyed by
/// `group_key_{conversationId}_{version}`.
library;

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'secure_key_store.dart';

/// Prefix used to mark group-encrypted payloads so we can distinguish them
/// from plaintext or Signal-encrypted DM payloads.
const groupEncryptedPrefix = 'GRP1:';

class GroupCryptoService {
  final String serverUrl;
  String _token = '';

  /// In-memory cache: conversationId -> (version, raw key bytes).
  final Map<String, (int, Uint8List)> _keyCache = {};

  static final _aesGcm = AesGcm.with256bits();

  GroupCryptoService({required this.serverUrl});

  void setToken(String token) {
    _token = token;
  }

  // -----------------------------------------------------------------------
  // Key generation
  // -----------------------------------------------------------------------

  /// Generate a random 32-byte AES-256 key, returned as base64.
  static String generateGroupKey() {
    final secretKey = SecretKeyData.random(length: 32);
    return base64Encode(secretKey.bytes);
  }

  // -----------------------------------------------------------------------
  // Encrypt / decrypt
  // -----------------------------------------------------------------------

  /// Encrypt [plaintext] with the given base64-encoded AES-256 key.
  ///
  /// Returns `GRP1:` prefix + base64(nonce(12) || ciphertext || tag(16)).
  static Future<String> encryptGroupMessage(
    String plaintext,
    String keyBase64,
  ) async {
    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);
    final plaintextBytes = utf8.encode(plaintext);

    final secretBox = await _aesGcm.encrypt(
      plaintextBytes,
      secretKey: secretKey,
    );

    // Wire format: nonce(12) || ciphertext || mac(16)
    final nonce = Uint8List.fromList(secretBox.nonce);
    final ciphertext = Uint8List.fromList(secretBox.cipherText);
    final mac = Uint8List.fromList(secretBox.mac.bytes);

    final wire = Uint8List(nonce.length + ciphertext.length + mac.length);
    wire.setRange(0, 12, nonce);
    wire.setRange(12, 12 + ciphertext.length, ciphertext);
    wire.setRange(12 + ciphertext.length, wire.length, mac);

    return '$groupEncryptedPrefix${base64Encode(wire)}';
  }

  /// Decrypt a group message produced by [encryptGroupMessage].
  ///
  /// [ciphertextWithPrefix] must start with `GRP1:`.
  static Future<String> decryptGroupMessage(
    String ciphertextWithPrefix,
    String keyBase64,
  ) async {
    if (!ciphertextWithPrefix.startsWith(groupEncryptedPrefix)) {
      throw FormatException('Not a group-encrypted message (missing prefix)');
    }

    final b64 = ciphertextWithPrefix.substring(groupEncryptedPrefix.length);
    final wire = Uint8List.fromList(base64Decode(b64));

    if (wire.length < 12 + 16) {
      throw FormatException('Group ciphertext too short: ${wire.length} bytes');
    }

    final nonce = wire.sublist(0, 12);
    final ciphertext = wire.sublist(12, wire.length - 16);
    final macBytes = wire.sublist(wire.length - 16);

    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes));

    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: secretKey);

    return utf8.decode(plainBytes);
  }

  // -----------------------------------------------------------------------
  // Key management (fetch / cache / rotate)
  // -----------------------------------------------------------------------

  /// Get the group key for [conversationId], using the in-memory cache first,
  /// then falling back to [SecureKeyStore], and finally fetching from the
  /// server.
  ///
  /// Returns `(version, keyBase64)` or null if unavailable.
  Future<(int, String)?> getGroupKey(String conversationId) async {
    // 1. In-memory cache
    if (_keyCache.containsKey(conversationId)) {
      final (version, bytes) = _keyCache[conversationId]!;
      return (version, base64Encode(bytes));
    }

    // 2. Secure storage
    final store = SecureKeyStore.instance;
    final allEntries = await store.readAll();
    final prefix = 'group_key_${conversationId}_';
    int? bestVersion;
    String? bestKey;
    for (final entry in allEntries.entries) {
      if (entry.key.startsWith(prefix)) {
        final vStr = entry.key.substring(prefix.length);
        final v = int.tryParse(vStr);
        if (v != null && (bestVersion == null || v > bestVersion)) {
          bestVersion = v;
          bestKey = entry.value;
        }
      }
    }
    if (bestVersion != null && bestKey != null) {
      _keyCache[conversationId] = (
        bestVersion,
        Uint8List.fromList(base64Decode(bestKey)),
      );
      return (bestVersion, bestKey);
    }

    // 3. Fetch from server
    return fetchGroupKey(conversationId);
  }

  /// Fetch the latest group key from the server and cache it.
  ///
  /// Returns `(version, keyBase64)` or null on failure.
  Future<(int, String)?> fetchGroupKey(String conversationId) async {
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys/latest'),
        headers: {'Authorization': 'Bearer $_token'},
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[GroupCrypto] Failed to fetch key for $conversationId: '
          '${response.statusCode}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final encryptedKey = data['encrypted_key'] as String;
      final version = data['key_version'] as int;

      await _cacheKey(conversationId, version, encryptedKey);
      return (version, encryptedKey);
    } catch (e) {
      debugPrint('[GroupCrypto] fetchGroupKey error: $e');
      return null;
    }
  }

  /// Generate a new group key and upload it to the server.
  ///
  /// Returns the new version number, or null on failure.
  Future<int?> rotateGroupKey(String conversationId) async {
    // Determine next version
    final current = await getGroupKey(conversationId);
    final nextVersion = current != null ? current.$1 + 1 : 1;

    final newKey = generateGroupKey();

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'encrypted_key': newKey, 'key_version': nextVersion}),
      );

      if (response.statusCode != 201) {
        debugPrint(
          '[GroupCrypto] Failed to upload key: '
          '${response.statusCode} ${response.body}',
        );
        return null;
      }

      await _cacheKey(conversationId, nextVersion, newKey);
      return nextVersion;
    } catch (e) {
      debugPrint('[GroupCrypto] rotateGroupKey error: $e');
      return null;
    }
  }

  /// Invalidate the cached key for a conversation so the next call to
  /// [getGroupKey] fetches a fresh copy from the server.
  Future<void> invalidateCache(String conversationId) async {
    _keyCache.remove(conversationId);
    // We keep secure-storage entries around for offline decryption of
    // older messages, but clear the in-memory cache so we re-fetch.
  }

  /// Clear all group keys (for logout).
  Future<void> clearAll() async {
    _keyCache.clear();
    final store = SecureKeyStore.instance;
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith('group_key_')) {
        await store.delete(key);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  Future<void> _cacheKey(
    String conversationId,
    int version,
    String keyBase64,
  ) async {
    final bytes = Uint8List.fromList(base64Decode(keyBase64));
    _keyCache[conversationId] = (version, bytes);

    final store = SecureKeyStore.instance;
    await store.write('group_key_${conversationId}_$version', keyBase64);
  }
}
