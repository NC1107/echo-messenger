/// End-to-end encryption service using the Signal Protocol (X3DH + Double Ratchet).
///
/// Replaces the previous static DH key exchange with proper Signal Protocol
/// sessions providing per-message forward secrecy and break-in recovery.
///
/// Keys and session state are persisted via SharedPreferences for prototype
/// simplicity. In production, use platform-specific secure storage.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'signal_session.dart';
import 'signal_x3dh.dart';

class CryptoService {
  static const _identityKeyPref = 'echo_identity_key';
  static const _identityPubKeyPref = 'echo_identity_pub_key';
  static const _signingKeyPref = 'echo_signing_key';
  static const _signingPubKeyPref = 'echo_signing_pub_key';
  static const _signedPrekeyPref = 'echo_signed_prekey';
  static const _signedPrekeyPubPref = 'echo_signed_prekey_pub';
  static const _sessionPrefix = 'echo_signal_session_';

  final String serverUrl;
  String _token = '';

  SimpleKeyPair? _identityKeyPair;
  SimpleKeyPair? _signedPrekeyPair;
  SimpleKeyPair? _signingKeyPair;
  final Map<String, SignalSession> _sessions = {};
  bool _keysAreFresh = false;

  final _x25519 = X25519();
  final _ed25519 = Ed25519();

  CryptoService({required this.serverUrl});

  void setToken(String token) {
    _token = token;
  }

  bool get isInitialized => _identityKeyPair != null;
  bool get keysAreFresh => _keysAreFresh;

  /// Initialize: load or generate identity key pair, signing key, and signed prekey.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedPrivate = prefs.getString(_identityKeyPref);

      if (storedPrivate != null) {
        // Restore identity key pair
        final privateBytes = base64Decode(storedPrivate);
        final publicBytes = base64Decode(prefs.getString(_identityPubKeyPref)!);
        _identityKeyPair = SimpleKeyPairData(
          privateBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );

        // Restore Ed25519 signing key pair
        final sigPriv = prefs.getString(_signingKeyPref);
        final sigPub = prefs.getString(_signingPubKeyPref);
        if (sigPriv != null && sigPub != null) {
          _signingKeyPair = SimpleKeyPairData(
            base64Decode(sigPriv),
            publicKey: SimplePublicKey(
              base64Decode(sigPub),
              type: KeyPairType.ed25519,
            ),
            type: KeyPairType.ed25519,
          );
        } else {
          // Legacy migration: generate signing key if missing
          _signingKeyPair = await _ed25519.newKeyPair();
          await _saveSigningKey(prefs);
          _keysAreFresh = true;
        }

        // Restore signed prekey pair
        final spkPriv = prefs.getString(_signedPrekeyPref);
        final spkPub = prefs.getString(_signedPrekeyPubPref);
        if (spkPriv != null && spkPub != null) {
          _signedPrekeyPair = SimpleKeyPairData(
            base64Decode(spkPriv),
            publicKey: SimplePublicKey(
              base64Decode(spkPub),
              type: KeyPairType.x25519,
            ),
            type: KeyPairType.x25519,
          );
        } else {
          // Legacy migration: generate signed prekey if missing
          _signedPrekeyPair = await _x25519.newKeyPair();
          await _saveSignedPrekey(prefs);
          _keysAreFresh = true;
        }

        if (!_keysAreFresh) {
          _keysAreFresh = false;
        }

        // Load persisted sessions
        await _loadSessions(prefs);
      } else {
        // Generate all keys fresh
        _identityKeyPair = await _x25519.newKeyPair();
        _signingKeyPair = await _ed25519.newKeyPair();
        _signedPrekeyPair = await _x25519.newKeyPair();

        final privateBytes = await (_identityKeyPair as SimpleKeyPairData)
            .extractPrivateKeyBytes();
        final publicKey = await _identityKeyPair!.extractPublicKey();

        await prefs.setString(_identityKeyPref, base64Encode(privateBytes));
        await prefs.setString(
          _identityPubKeyPref,
          base64Encode(publicKey.bytes),
        );
        await _saveSigningKey(prefs);
        await _saveSignedPrekey(prefs);

        _keysAreFresh = true;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _saveSigningKey(SharedPreferences prefs) async {
    final sigPrivBytes = await (_signingKeyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();
    final sigPubKey = await _signingKeyPair!.extractPublicKey();
    await prefs.setString(_signingKeyPref, base64Encode(sigPrivBytes));
    await prefs.setString(_signingPubKeyPref, base64Encode(sigPubKey.bytes));
  }

  Future<void> _saveSignedPrekey(SharedPreferences prefs) async {
    final spkPrivBytes = await (_signedPrekeyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();
    final spkPubKey = await _signedPrekeyPair!.extractPublicKey();
    await prefs.setString(_signedPrekeyPref, base64Encode(spkPrivBytes));
    await prefs.setString(_signedPrekeyPubPref, base64Encode(spkPubKey.bytes));
  }

  /// Load persisted Signal sessions from SharedPreferences.
  Future<void> _loadSessions(SharedPreferences prefs) async {
    _sessions.clear();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_sessionPrefix)) {
        final peerId = key.substring(_sessionPrefix.length);
        final jsonStr = prefs.getString(key);
        if (jsonStr != null) {
          try {
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            _sessions[peerId] = SignalSession.fromJson(json);
          } catch (e) {
            debugPrint('[Crypto] Failed to load session for $peerId: $e');
            await prefs.remove(key);
          }
        }
      }
    }
  }

  /// Persist a Signal session to SharedPreferences.
  Future<void> _saveSession(String peerId, SignalSession session) async {
    final prefs = await SharedPreferences.getInstance();
    final json = await session.toJson();
    await prefs.setString('$_sessionPrefix$peerId', jsonEncode(json));
  }

  /// Upload our public keys to the server as a PreKey bundle.
  ///
  /// Includes:
  /// - X25519 identity key
  /// - Ed25519 signing key (for prekey signature verification)
  /// - Signed prekey with real Ed25519 signature
  /// - One-time prekeys
  Future<void> uploadKeys() async {
    if (_identityKeyPair == null) await init();

    final publicKey = await _identityKeyPair!.extractPublicKey();
    final pubKeyB64 = base64Encode(publicKey.bytes);

    // Get the signed prekey public key
    final spkPub = await _signedPrekeyPair!.extractPublicKey();
    final spkPubB64 = base64Encode(spkPub.bytes);

    // Sign the signed prekey with Ed25519
    final signature = await _ed25519.sign(
      spkPub.bytes,
      keyPair: _signingKeyPair!,
    );
    final sigB64 = base64Encode(signature.bytes);

    // Get Ed25519 signing public key
    final signingPub = await _signingKeyPair!.extractPublicKey();
    final signingPubB64 = base64Encode(signingPub.bytes);

    // Generate one-time prekeys
    final otps = <Map<String, dynamic>>[];
    for (var i = 0; i < 10; i++) {
      final otpPair = await _x25519.newKeyPair();
      final otpPub = await otpPair.extractPublicKey();
      otps.add({'key_id': i, 'public_key': base64Encode(otpPub.bytes)});
    }

    final body = jsonEncode({
      'identity_key': pubKeyB64,
      'signing_key': signingPubB64,
      'signed_prekey': spkPubB64,
      'signed_prekey_signature': sigB64,
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

  /// Get or create a Signal session with a peer.
  ///
  /// If a session already exists in memory or was loaded from storage, returns it.
  /// Otherwise, fetches the peer's prekey bundle from the server, performs X3DH
  /// to establish a shared secret, and initializes a new Double Ratchet session.
  Future<SignalSession> getOrCreateSession(String peerUserId) async {
    if (_sessions.containsKey(peerUserId)) {
      return _sessions[peerUserId]!;
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
    final bobIdentityKeyBytes = base64Decode(data['identity_key'] as String);
    final bobSignedPrekeyBytes = base64Decode(data['signed_prekey'] as String);

    final bobIdentityKey = SimplePublicKey(
      bobIdentityKeyBytes,
      type: KeyPairType.x25519,
    );
    final bobSignedPrekey = SimplePublicKey(
      bobSignedPrekeyBytes,
      type: KeyPairType.x25519,
    );

    // Parse optional one-time prekey
    SimplePublicKey? bobOneTimePrekey;
    if (data['one_time_prekey'] != null) {
      final otpBytes = base64Decode(data['one_time_prekey'] as String);
      bobOneTimePrekey = SimplePublicKey(otpBytes, type: KeyPairType.x25519);
    }

    // Perform X3DH as Alice (initiator)
    final x3dhResult = await X3DH.initiate(
      aliceIdentity: _identityKeyPair!,
      bobIdentityKey: bobIdentityKey,
      bobSignedPrekey: bobSignedPrekey,
      bobOneTimePrekey: bobOneTimePrekey,
    );

    // Initialize Double Ratchet as Alice.
    // Bob's signed prekey serves as his initial ratchet public key.
    final session = await SignalSession.initAlice(
      x3dhResult.sharedSecret,
      bobSignedPrekey,
    );

    _sessions[peerUserId] = session;
    await _saveSession(peerUserId, session);

    return session;
  }

  /// Encrypt a plaintext message for a specific peer.
  ///
  /// Returns a base64-encoded string containing the Signal Protocol wire format:
  /// header_len (4 LE) || header (40) || nonce (12) || ciphertext || tag (16).
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    final session = await getOrCreateSession(peerUserId);
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));

    final wire = await session.encrypt(plaintextBytes);

    // Persist updated session state after encryption advances the chain
    await _saveSession(peerUserId, session);

    return base64Encode(wire);
  }

  /// Decrypt a base64-encoded ciphertext from a specific peer.
  ///
  /// Handles DH ratchet steps and out-of-order message delivery automatically.
  Future<String> decryptMessage(String peerUserId, String ciphertextB64) async {
    final session = await getOrCreateSession(peerUserId);
    final wire = base64Decode(ciphertextB64);

    final plainBytes = await session.decrypt(Uint8List.fromList(wire));

    // Persist updated session state after decryption may advance the chain
    await _saveSession(peerUserId, session);

    return utf8.decode(plainBytes);
  }

  /// Check if we have a session for a peer (no network call needed).
  bool hasSessionKey(String peerUserId) {
    return _sessions.containsKey(peerUserId);
  }

  /// Invalidate the cached session for a peer so the next call to
  /// [getOrCreateSession] will re-fetch from the server and create a new session.
  Future<void> invalidateSessionKey(String peerUserId) async {
    _sessions.remove(peerUserId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_sessionPrefix$peerUserId');
  }

  /// Reset all keys: delete identity + session keys, regenerate, and upload.
  Future<void> resetAllKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_identityKeyPref);
    await prefs.remove(_identityPubKeyPref);
    await prefs.remove(_signingKeyPref);
    await prefs.remove(_signingPubKeyPref);
    await prefs.remove(_signedPrekeyPref);
    await prefs.remove(_signedPrekeyPubPref);
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_sessionPrefix)) {
        await prefs.remove(key);
      }
    }
    _sessions.clear();
    _identityKeyPair = null;
    _signingKeyPair = null;
    _signedPrekeyPair = null;
    await init(); // Generates new keys, sets _keysAreFresh = true
    await uploadKeys();
  }

  /// Clear all stored keys (for logout).
  Future<void> clearKeys() async {
    _identityKeyPair = null;
    _signingKeyPair = null;
    _signedPrekeyPair = null;
    _sessions.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_identityKeyPref);
    await prefs.remove(_identityPubKeyPref);
    await prefs.remove(_signingKeyPref);
    await prefs.remove(_signingPubKeyPref);
    await prefs.remove(_signedPrekeyPref);
    await prefs.remove(_signedPrekeyPubPref);
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_sessionPrefix)) {
        await prefs.remove(key);
      }
    }
  }
}
