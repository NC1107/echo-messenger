/// AES-256-GCM group encryption service with per-member key distribution.
///
/// Each group conversation has a symmetric AES key shared by all members.
/// Instead of uploading the raw key to the server, the key is encrypted
/// individually for each member using their X25519 identity public key
/// (ECDH + HKDF + AES-GCM wrapping). The server only ever sees per-member
/// encrypted envelopes and cannot recover the plaintext group key.
///
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

import 'crypto_service.dart';
import 'secure_key_store.dart';

/// Prefix used to mark group-encrypted payloads so we can distinguish them
/// from plaintext or Signal-encrypted DM payloads.
const groupEncryptedPrefix = 'GRP1:';

class GroupCryptoService {
  final String serverUrl;
  String _token = '';

  /// Reference to the CryptoService for identity key operations and
  /// per-user encryption/decryption (ECDH key wrapping).
  CryptoService? _cryptoService;

  /// In-memory cache: conversationId -> (version, raw key bytes).
  final Map<String, (int, Uint8List)> _keyCache = {};

  /// Groups known to not have encryption enabled. Prevents repeated 400
  /// requests against the server for plaintext groups.
  final Set<String> _unencryptedGroups = {};

  static final _aesGcm = AesGcm.with256bits();

  GroupCryptoService({required this.serverUrl});

  /// Set the CryptoService instance for identity key operations.
  void setCryptoService(CryptoService service) {
    _cryptoService = service;
  }

  /// Mark a group as unencrypted so [getGroupKey] short-circuits.
  void markUnencrypted(String conversationId) {
    _unencryptedGroups.add(conversationId);
  }

  /// Mark a group as encrypted (removes from the unencrypted set).
  void markEncrypted(String conversationId) {
    _unencryptedGroups.remove(conversationId);
  }

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
    // Skip server call for groups known to be unencrypted
    if (_unencryptedGroups.contains(conversationId)) return null;

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
  /// The server returns a per-member encrypted envelope. We decrypt it using
  /// our identity private key to recover the raw AES group key.
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

      // Try to decrypt the envelope using our identity key.
      // If _cryptoService is available, the encrypted_key is a per-member
      // envelope that must be unwrapped. If not, assume legacy plaintext key.
      String rawKeyB64;
      if (_cryptoService != null && encryptedKey != '__envelope__') {
        try {
          final rawKeyBytes = await _cryptoService!.decryptFromUser(
            encryptedKey,
          );
          rawKeyB64 = base64Encode(rawKeyBytes);
        } catch (e) {
          // Fallback: treat as legacy plaintext key (migration path)
          debugPrint(
            '[GroupCrypto] Envelope decrypt failed, trying as legacy: $e',
          );
          rawKeyB64 = encryptedKey;
        }
      } else {
        rawKeyB64 = encryptedKey;
      }

      await _cacheKey(conversationId, version, rawKeyB64);
      return (version, rawKeyB64);
    } catch (e) {
      debugPrint('[GroupCrypto] fetchGroupKey error: $e');
      return null;
    }
  }

  /// Generate a new group key and upload per-member encrypted envelopes.
  ///
  /// For each group member, the raw AES key is encrypted using their identity
  /// public key via ECDH + HKDF + AES-GCM (CryptoService.encryptForUser).
  /// The server never sees the plaintext key.
  ///
  /// Returns the new version number, or null on failure.
  Future<int?> rotateGroupKey(
    String conversationId,
    List<Map<String, dynamic>> members,
  ) async {
    if (_cryptoService == null) {
      debugPrint('[GroupCrypto] Cannot rotate key: no CryptoService set');
      return null;
    }

    // Determine next version
    final current = await getGroupKey(conversationId);
    final nextVersion = current != null ? current.$1 + 1 : 1;

    final newKey = generateGroupKey();
    final newKeyBytes = Uint8List.fromList(base64Decode(newKey));

    // Build per-member envelopes
    final envelopes = <Map<String, dynamic>>[];
    for (final member in members) {
      final userId = member['user_id'] as String;
      final identityKeyB64 = member['identity_key'] as String?;

      if (identityKeyB64 == null) {
        debugPrint('[GroupCrypto] Skipping member $userId: no identity key');
        continue;
      }

      final identityKeyBytes = base64Decode(identityKeyB64);
      final encryptedEnvelope = await _cryptoService!.encryptForUser(
        newKeyBytes,
        Uint8List.fromList(identityKeyBytes),
      );

      envelopes.add({'user_id': userId, 'encrypted_key': encryptedEnvelope});
    }

    if (envelopes.isEmpty) {
      debugPrint('[GroupCrypto] No valid envelopes to upload');
      return null;
    }

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'key_version': nextVersion, 'envelopes': envelopes}),
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
    _unencryptedGroups.clear();
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
