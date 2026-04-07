/// End-to-end encryption service using the Signal Protocol (X3DH + Double Ratchet).
///
/// Replaces the previous static DH key exchange with proper Signal Protocol
/// sessions providing per-message forward secrecy and break-in recovery.
///
/// Keys and session state are persisted via [SecureKeyStore] (platform-specific
/// secure storage: Keychain, Keystore, libsecret, DPAPI, etc.).
/// On first run after the migration, any keys found in SharedPreferences are
/// automatically moved to secure storage and removed from SharedPreferences.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_key_store.dart';
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

  /// All crypto key names that should live in secure storage.
  static const _allCryptoKeys = [
    _identityKeyPref,
    _identityPubKeyPref,
    _signingKeyPref,
    _signingPubKeyPref,
    _signedPrekeyPref,
    _signedPrekeyPubPref,
  ];

  final String serverUrl;
  String _token = '';

  SimpleKeyPair? _identityKeyPair;
  SimpleKeyPair? _signedPrekeyPair;
  SimpleKeyPair? _signingKeyPair;
  final Map<String, SignalSession> _sessions = {};
  X3dhInitResult? _lastX3dhResult;
  bool _keysAreFresh = false;

  final _x25519 = X25519();
  final _ed25519 = Ed25519();

  CryptoService({required this.serverUrl});

  void setToken(String token) {
    _token = token;
  }

  bool get isInitialized => _identityKeyPair != null;
  bool get keysAreFresh => _keysAreFresh;

  /// Migrate crypto keys from SharedPreferences to SecureKeyStore.
  ///
  /// Checks SharedPreferences for each crypto key; if found, copies it to
  /// secure storage and deletes from SharedPreferences. Session keys (prefixed
  /// with [_sessionPrefix]) are also migrated.
  Future<void> _migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final store = SecureKeyStore.instance;

    // Migrate identity + signing + signed prekey
    for (final key in _allCryptoKeys) {
      final value = prefs.getString(key);
      if (value != null) {
        await store.write(key, value);
        await prefs.remove(key);
        debugPrint(
          '[Crypto] Migrated $key from SharedPreferences to '
          'secure storage',
        );
      }
    }

    // Migrate session keys
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_sessionPrefix)) {
        final value = prefs.getString(key);
        if (value != null) {
          await store.write(key, value);
          await prefs.remove(key);
          debugPrint('[Crypto] Migrated session $key to secure storage');
        }
      }
    }
  }

  /// Initialize: load or generate identity key pair, signing key, and signed prekey.
  Future<void> init() async {
    try {
      // Run migration before anything else -- moves keys from SharedPreferences
      // into platform-secure storage if they exist there from a previous version.
      await _migrateFromSharedPreferences();

      final store = SecureKeyStore.instance;
      final storedPrivate = await store.read(_identityKeyPref);

      if (storedPrivate != null) {
        // Restore identity key pair
        final privateBytes = base64Decode(storedPrivate);
        final publicBytes = base64Decode(
          (await store.read(_identityPubKeyPref))!,
        );
        _identityKeyPair = SimpleKeyPairData(
          privateBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );

        // Restore Ed25519 signing key pair
        final sigPriv = await store.read(_signingKeyPref);
        final sigPub = await store.read(_signingPubKeyPref);
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
          await _saveSigningKey(store);
          _keysAreFresh = true;
        }

        // Restore signed prekey pair
        final spkPriv = await store.read(_signedPrekeyPref);
        final spkPub = await store.read(_signedPrekeyPubPref);
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
          await _saveSignedPrekey(store);
          _keysAreFresh = true;
        }

        if (!_keysAreFresh) {
          _keysAreFresh = false;
        }

        // Load persisted sessions
        await _loadSessions(store);
      } else {
        // Generate all keys fresh
        _identityKeyPair = await _x25519.newKeyPair();
        _signingKeyPair = await _ed25519.newKeyPair();
        _signedPrekeyPair = await _x25519.newKeyPair();

        final privateBytes = await (_identityKeyPair as SimpleKeyPairData)
            .extractPrivateKeyBytes();
        final publicKey = await _identityKeyPair!.extractPublicKey();

        await store.write(_identityKeyPref, base64Encode(privateBytes));
        await store.write(_identityPubKeyPref, base64Encode(publicKey.bytes));
        await _saveSigningKey(store);
        await _saveSignedPrekey(store);

        _keysAreFresh = true;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _saveSigningKey(SecureKeyStore store) async {
    final sigPrivBytes = await (_signingKeyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();
    final sigPubKey = await _signingKeyPair!.extractPublicKey();
    await store.write(_signingKeyPref, base64Encode(sigPrivBytes));
    await store.write(_signingPubKeyPref, base64Encode(sigPubKey.bytes));
  }

  Future<void> _saveSignedPrekey(SecureKeyStore store) async {
    final spkPrivBytes = await (_signedPrekeyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();
    final spkPubKey = await _signedPrekeyPair!.extractPublicKey();
    await store.write(_signedPrekeyPref, base64Encode(spkPrivBytes));
    await store.write(_signedPrekeyPubPref, base64Encode(spkPubKey.bytes));
  }

  /// Load persisted Signal sessions from secure storage.
  Future<void> _loadSessions(SecureKeyStore store) async {
    _sessions.clear();
    final allEntries = await store.readAll();
    for (final entry in allEntries.entries) {
      if (entry.key.startsWith(_sessionPrefix)) {
        final peerId = entry.key.substring(_sessionPrefix.length);
        try {
          final json = jsonDecode(entry.value) as Map<String, dynamic>;
          _sessions[peerId] = SignalSession.fromJson(json);
        } catch (e) {
          debugPrint('[Crypto] Failed to load session for $peerId: $e');
          await store.delete(entry.key);
        }
      }
    }
  }

  /// Persist a Signal session to secure storage.
  Future<void> _saveSession(String peerId, SignalSession session) async {
    final store = SecureKeyStore.instance;
    final json = await session.toJson();
    await store.write('$_sessionPrefix$peerId', jsonEncode(json));
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

    // Verify the signed prekey signature to prevent MITM / malicious server
    // substitution. The server returns `signing_key` and
    // `signed_prekey_signature` alongside the prekey bundle.
    final signingKeyB64 = data['signing_key'] as String?;
    final signatureB64 = data['signed_prekey_signature'] as String?;
    if (signingKeyB64 == null || signatureB64 == null) {
      throw Exception(
        'Prekey bundle for $peerUserId is missing signing_key or '
        'signed_prekey_signature -- cannot verify prekey authenticity',
      );
    }

    final signingKeyBytes = base64Decode(signingKeyB64);
    final signatureBytes = base64Decode(signatureB64);

    final signingPublicKey = SimplePublicKey(
      signingKeyBytes,
      type: KeyPairType.ed25519,
    );
    final isValid = await _ed25519.verify(
      bobSignedPrekeyBytes,
      signature: Signature(signatureBytes, publicKey: signingPublicKey),
    );
    if (!isValid) {
      throw Exception(
        'Signed prekey signature verification failed for $peerUserId '
        '-- possible MITM attack',
      );
    }

    final bobIdentityKey = SimplePublicKey(
      bobIdentityKeyBytes,
      type: KeyPairType.x25519,
    );
    final bobSignedPrekey = SimplePublicKey(
      bobSignedPrekeyBytes,
      type: KeyPairType.x25519,
    );

    // NOTE: One-time prekeys are not used because OTP private keys are not
    // persisted on the client. Both Alice and Bob must use 3-DH only so the
    // shared secrets match. OTPs are still uploaded/stored server-side for
    // future use once private-key persistence is implemented.

    // Perform X3DH as Alice (initiator) -- 3-DH only (no one-time prekey)
    final x3dhResult = await X3DH.initiate(
      aliceIdentity: _identityKeyPair!,
      bobIdentityKey: bobIdentityKey,
      bobSignedPrekey: bobSignedPrekey,
    );

    // Initialize Double Ratchet as Alice.
    // Bob's signed prekey serves as his initial ratchet public key.
    final session = await SignalSession.initAlice(
      x3dhResult.sharedSecret,
      bobSignedPrekey,
    );

    _sessions[peerUserId] = session;
    _lastX3dhResult = x3dhResult; // Save for initial message prefix
    await _saveSession(peerUserId, session);

    return session;
  }

  // Magic byte prefix for initial messages that include X3DH key exchange data.
  // Format: [0xEC, 0x01] || alice_identity_pub (32) || alice_ephemeral_pub (32) || session_wire
  static const _initialMsgMagic = [0xEC, 0x01];

  /// Encrypt a plaintext message for a specific peer.
  ///
  /// For the first message (new session), includes X3DH key exchange data
  /// so the receiver can establish the session as Bob.
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    final isNewSession = !_sessions.containsKey(peerUserId);
    final session = await getOrCreateSession(peerUserId);
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));

    final wire = await session.encrypt(plaintextBytes);

    Uint8List finalWire;
    if (isNewSession && _lastX3dhResult != null) {
      // First message: prepend magic + identity + ephemeral keys
      final idPub = (await _identityKeyPair!.extractPublicKey()).bytes;
      final ephPub = _lastX3dhResult!.ephemeralPublic.bytes;
      finalWire = Uint8List(2 + 32 + 32 + wire.length);
      finalWire[0] = _initialMsgMagic[0];
      finalWire[1] = _initialMsgMagic[1];
      finalWire.setRange(2, 34, Uint8List.fromList(idPub));
      finalWire.setRange(34, 66, Uint8List.fromList(ephPub));
      finalWire.setRange(66, finalWire.length, wire);
      _lastX3dhResult = null; // Clear after use
    } else {
      finalWire = wire;
    }

    await _saveSession(peerUserId, session);
    return base64Encode(finalWire);
  }

  /// Decrypt a base64-encoded ciphertext from a specific peer.
  ///
  /// If this is an initial message (contains X3DH key exchange prefix),
  /// establishes the session as Bob (responder) before decrypting.
  Future<String> decryptMessage(String peerUserId, String ciphertextB64) async {
    final fullWire = Uint8List.fromList(base64Decode(ciphertextB64));

    // Check for initial message magic prefix
    if (fullWire.length > 66 &&
        fullWire[0] == _initialMsgMagic[0] &&
        fullWire[1] == _initialMsgMagic[1] &&
        !_sessions.containsKey(peerUserId)) {
      // This is an initial message -- establish session as Bob
      final aliceIdentityPub = SimplePublicKey(
        fullWire.sublist(2, 34),
        type: KeyPairType.x25519,
      );
      final aliceEphemeralPub = SimplePublicKey(
        fullWire.sublist(34, 66),
        type: KeyPairType.x25519,
      );
      final sessionWire = fullWire.sublist(66);

      // Compute X3DH as Bob (responder)
      if (_signedPrekeyPair == null) await init();
      final sharedSecret = await X3DH.respond(
        bobIdentity: _identityKeyPair!,
        bobSignedPrekey: _signedPrekeyPair!,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: aliceEphemeralPub,
      );

      // Initialize Double Ratchet as Bob
      final session = await SignalSession.initBob(
        sharedSecret,
        _signedPrekeyPair!,
      );

      // Decrypt the actual message
      final plainBytes = await session.decrypt(sessionWire);
      _sessions[peerUserId] = session;
      await _saveSession(peerUserId, session);
      return utf8.decode(plainBytes);
    }

    // Normal message -- use existing session
    final session = await getOrCreateSession(peerUserId);
    final plainBytes = await session.decrypt(fullWire);
    await _saveSession(peerUserId, session);
    return utf8.decode(plainBytes);
  }

  /// Check whether a session can be established with [peerUserId].
  ///
  /// Returns true immediately if a session already exists. Otherwise queries
  /// the server for the peer's key bundle and returns true when one is
  /// available.
  Future<bool> canEstablishSession(String peerUserId) async {
    if (_sessions.containsKey(peerUserId)) return true;
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/keys/bundle/$peerUserId'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Check if we have a session for a peer (no network call needed).
  bool hasSessionKey(String peerUserId) {
    return _sessions.containsKey(peerUserId);
  }

  /// Invalidate the cached session for a peer so the next call to
  /// [getOrCreateSession] will re-fetch from the server and create a new session.
  Future<void> invalidateSessionKey(String peerUserId) async {
    _sessions.remove(peerUserId);
    final store = SecureKeyStore.instance;
    await store.delete('$_sessionPrefix$peerUserId');
  }

  /// Reset all keys: delete identity + session keys, regenerate, and upload.
  Future<void> resetAllKeys() async {
    final store = SecureKeyStore.instance;
    for (final key in _allCryptoKeys) {
      await store.delete(key);
    }
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith(_sessionPrefix)) {
        await store.delete(key);
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
    final store = SecureKeyStore.instance;
    for (final key in _allCryptoKeys) {
      await store.delete(key);
    }
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith(_sessionPrefix)) {
        await store.delete(key);
      }
    }
  }
}
