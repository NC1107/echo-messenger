/// End-to-end encryption service using X25519 + AES-GCM.
///
/// Handles key generation, key exchange, and message encryption/decryption.
/// Keys are persisted via SharedPreferences for prototype simplicity.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class CryptoService {
  static const _identityKeyPref = 'echo_identity_key';
  static const _identityPubKeyPref = 'echo_identity_pub_key';
  static const _sessionKeyPrefix = 'echo_session_';

  final String serverUrl;
  String _token = '';

  SimpleKeyPair? _identityKeyPair;
  final Map<String, SecretKey> _sessionKeys = {};

  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();

  CryptoService({required this.serverUrl});

  void setToken(String token) {
    _token = token;
  }

  bool get isInitialized => _identityKeyPair != null;

  /// Initialize: load or generate identity key pair.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedPrivate = prefs.getString(_identityKeyPref);

      if (storedPrivate != null) {
        final privateBytes = base64Decode(storedPrivate);
        final publicBytes = base64Decode(prefs.getString(_identityPubKeyPref)!);
        _identityKeyPair = SimpleKeyPairData(
          privateBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );
      } else {
        _identityKeyPair = await _x25519.newKeyPair();
        final privateBytes = await (_identityKeyPair as SimpleKeyPairData)
            .extractPrivateKeyBytes();
        final publicKey = await _identityKeyPair!.extractPublicKey();

        await prefs.setString(_identityKeyPref, base64Encode(privateBytes));
        await prefs.setString(
          _identityPubKeyPref,
          base64Encode(publicKey.bytes),
        );
      }

      // Load cached session keys
      for (final key in prefs.getKeys()) {
        if (key.startsWith(_sessionKeyPrefix)) {
          final userId = key.substring(_sessionKeyPrefix.length);
          final secretBytes = base64Decode(prefs.getString(key)!);
          _sessionKeys[userId] = SecretKeyData(secretBytes);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Upload our public key to the server as a PreKey bundle.
  Future<void> uploadKeys() async {
    if (_identityKeyPair == null) await init();

    final publicKey = await _identityKeyPair!.extractPublicKey();
    final pubKeyB64 = base64Encode(publicKey.bytes);

    // For the prototype, we use the same key as identity, signed prekey,
    // and generate a few one-time prekeys.
    final otps = <Map<String, dynamic>>[];
    for (var i = 0; i < 10; i++) {
      final otpPair = await _x25519.newKeyPair();
      final otpPub = await otpPair.extractPublicKey();
      otps.add({'key_id': i, 'public_key': base64Encode(otpPub.bytes)});
    }

    final body = jsonEncode({
      'identity_key': pubKeyB64,
      'signed_prekey': pubKeyB64,
      'signed_prekey_signature': base64Encode(
        Uint8List(64),
      ), // Placeholder for prototype
      'signed_prekey_id': 1,
      'one_time_prekeys': otps,
    });

    final response = await http.post(
      Uri.parse('$serverUrl/api/keys/upload'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );

    if (response.statusCode != 201) {
      throw Exception(
        'Failed to upload keys: HTTP ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Fetch a peer's public key and derive a shared secret via X25519 DH.
  Future<SecretKey> getOrCreateSessionKey(String peerUserId) async {
    if (_sessionKeys.containsKey(peerUserId)) {
      return _sessionKeys[peerUserId]!;
    }

    if (_identityKeyPair == null) await init();

    // Fetch peer's PreKey bundle from server
    final response = await http.get(
      Uri.parse('$serverUrl/api/keys/bundle/$peerUserId'),
      headers: {'Authorization': 'Bearer $_token'},
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch keys for $peerUserId: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final theirPubKeyBytes = base64Decode(data['identity_key'] as String);
    final theirPubKey = SimplePublicKey(
      theirPubKeyBytes,
      type: KeyPairType.x25519,
    );

    // Perform X25519 DH to derive shared secret
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: _identityKeyPair!,
      remotePublicKey: theirPubKey,
    );

    // Use HKDF to derive a proper 256-bit key from the shared secret.
    // CRITICAL: both parties must use the same info string, so we sort
    // the user IDs to create a canonical session identifier.
    final myPubKey = await _identityKeyPair!.extractPublicKey();
    final myPubB64 = base64Encode(myPubKey.bytes);
    final theirPubB64 = base64Encode(theirPubKeyBytes);
    final sortedKeys = [myPubB64, theirPubB64]..sort();
    final sessionInfo = 'echo-session-${sortedKeys[0]}-${sortedKeys[1]}';

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derivedKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('EchoE2EE'),
      info: utf8.encode(sessionInfo),
    );

    _sessionKeys[peerUserId] = derivedKey;

    // Persist the session key
    final prefs = await SharedPreferences.getInstance();
    final derivedBytes = await derivedKey.extractBytes();
    await prefs.setString(
      '$_sessionKeyPrefix$peerUserId',
      base64Encode(derivedBytes),
    );

    return derivedKey;
  }

  /// Encrypt a plaintext message for a specific peer.
  ///
  /// Returns a base64-encoded string containing nonce + ciphertext + tag.
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    final sessionKey = await getOrCreateSessionKey(peerUserId);
    final plaintextBytes = utf8.encode(plaintext);

    final secretBox = await _aesGcm.encrypt(
      plaintextBytes,
      secretKey: sessionKey,
    );

    // Pack: nonce (12) || ciphertext || mac (16)
    final packed = Uint8List(
      secretBox.nonce.length +
          secretBox.cipherText.length +
          secretBox.mac.bytes.length,
    );
    var offset = 0;
    packed.setRange(offset, offset + secretBox.nonce.length, secretBox.nonce);
    offset += secretBox.nonce.length;
    packed.setRange(
      offset,
      offset + secretBox.cipherText.length,
      secretBox.cipherText,
    );
    offset += secretBox.cipherText.length;
    packed.setRange(
      offset,
      offset + secretBox.mac.bytes.length,
      secretBox.mac.bytes,
    );

    return base64Encode(packed);
  }

  /// Decrypt a base64-encoded ciphertext from a specific peer.
  Future<String> decryptMessage(String peerUserId, String ciphertextB64) async {
    final sessionKey = await getOrCreateSessionKey(peerUserId);
    final packed = base64Decode(ciphertextB64);

    if (packed.length < 12 + 16) {
      throw Exception('Ciphertext too short');
    }

    final nonce = packed.sublist(0, 12);
    final cipherText = packed.sublist(12, packed.length - 16);
    final mac = Mac(packed.sublist(packed.length - 16));

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: sessionKey);

    return utf8.decode(plainBytes);
  }

  /// Check if we have a session key for a peer (no network call needed).
  bool hasSessionKey(String peerUserId) {
    return _sessionKeys.containsKey(peerUserId);
  }

  /// Invalidate the cached session key for a peer so the next call to
  /// [getOrCreateSessionKey] will re-fetch from the server.
  Future<void> invalidateSessionKey(String peerUserId) async {
    _sessionKeys.remove(peerUserId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_sessionKeyPrefix$peerUserId');
  }

  /// Clear all stored keys (for logout).
  Future<void> clearKeys() async {
    _identityKeyPair = null;
    _sessionKeys.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_identityKeyPref);
    await prefs.remove(_identityPubKeyPref);
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_sessionKeyPrefix)) {
        await prefs.remove(key);
      }
    }
  }
}
