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
  static const _peerIdentityPrefix = 'echo_peer_identity_';
  static const _otpPrivatePrefix = 'echo_otp_private_';
  static const _signedPrekeyCreatedAtPref = 'echo_signed_prekey_created_at';
  static const _signedPrekeyPreviousPref = 'echo_signed_prekey_previous';
  static const _signedPrekeyPreviousPubPref = 'echo_signed_prekey_previous_pub';

  /// Duration after which the signed prekey should be rotated.
  static const _signedPrekeyMaxAge = Duration(days: 7);

  /// Grace period to keep the old signed prekey for peers that have not yet
  /// fetched the new one.
  static const _signedPrekeyGracePeriod = Duration(days: 14);

  /// All crypto key names that should live in secure storage.
  static const _allCryptoKeys = [
    _identityKeyPref,
    _identityPubKeyPref,
    _signingKeyPref,
    _signingPubKeyPref,
    _signedPrekeyPref,
    _signedPrekeyPubPref,
    _signedPrekeyCreatedAtPref,
    _signedPrekeyPreviousPref,
    _signedPrekeyPreviousPubPref,
  ];

  final String serverUrl;
  String _token = '';

  SimpleKeyPair? _identityKeyPair;
  SimpleKeyPair? _signedPrekeyPair;
  SimpleKeyPair? _signingKeyPair;
  final Map<String, SignalSession> _sessions = {};
  X3dhInitResult? _lastX3dhResult;
  int? _lastOtpKeyId;
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

        // Check if signed prekey needs rotation
        await _rotateSignedPrekeyIfNeeded(store);
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
        await store.write(
          _signedPrekeyCreatedAtPref,
          DateTime.now().toIso8601String(),
        );

        _keysAreFresh = true;
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Rotate the signed prekey if it is older than [_signedPrekeyMaxAge].
  ///
  /// The old key pair is kept as a "previous" signed prekey for a grace period
  /// so that peers who fetched the old bundle can still complete X3DH.
  Future<void> _rotateSignedPrekeyIfNeeded(SecureKeyStore store) async {
    final createdAtStr = await store.read(_signedPrekeyCreatedAtPref);
    if (createdAtStr == null) {
      // No timestamp -- store current time and skip rotation this cycle.
      await store.write(
        _signedPrekeyCreatedAtPref,
        DateTime.now().toIso8601String(),
      );
      return;
    }

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return;

    final age = DateTime.now().difference(createdAt);
    if (age < _signedPrekeyMaxAge) return;

    debugPrint('[Crypto] Signed prekey is ${age.inDays} days old -- rotating');

    // Move current signed prekey to "previous" slot
    final currentPriv = await store.read(_signedPrekeyPref);
    final currentPub = await store.read(_signedPrekeyPubPref);
    if (currentPriv != null && currentPub != null) {
      await store.write(_signedPrekeyPreviousPref, currentPriv);
      await store.write(_signedPrekeyPreviousPubPref, currentPub);
    }

    // Generate new signed prekey
    _signedPrekeyPair = await _x25519.newKeyPair();
    await _saveSignedPrekey(store);
    await store.write(
      _signedPrekeyCreatedAtPref,
      DateTime.now().toIso8601String(),
    );

    _keysAreFresh = true;

    // Clean up previous prekey if it has exceeded the grace period
    await _cleanupPreviousPrekey(store);
  }

  /// Remove the previous signed prekey if it is older than the grace period.
  Future<void> _cleanupPreviousPrekey(SecureKeyStore store) async {
    final prevPriv = await store.read(_signedPrekeyPreviousPref);
    if (prevPriv == null) return;

    // The previous prekey was created when the current one replaced it.
    // We use the current prekey creation time minus max age as an estimate
    // for when the previous key was active. For simplicity, keep it for
    // one full grace period from now -- it will be cleaned up on the next
    // rotation cycle after that.
    final createdAtStr = await store.read(_signedPrekeyCreatedAtPref);
    if (createdAtStr == null) return;

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return;

    // If the current prekey is already older than the grace period minus
    // the max age, the previous one has definitely expired.
    final currentAge = DateTime.now().difference(createdAt);
    if (currentAge >= _signedPrekeyGracePeriod) {
      await store.delete(_signedPrekeyPreviousPref);
      await store.delete(_signedPrekeyPreviousPubPref);
      debugPrint('[Crypto] Cleaned up expired previous signed prekey');
    }
  }

  /// Fetch and cache a peer's identity public key from the server.
  ///
  /// Returns the key bytes, or null if unavailable.
  Future<Uint8List?> fetchPeerIdentityKey(String peerUserId) async {
    // Check cache first
    final store = SecureKeyStore.instance;
    final cached = await store.read('$_peerIdentityPrefix$peerUserId');
    if (cached != null) return Uint8List.fromList(base64Decode(cached));

    // Fetch from server
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/keys/bundle/$peerUserId'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final identityKeyB64 = data['identity_key'] as String?;
      if (identityKeyB64 == null) return null;

      // Cache for future use
      await store.write('$_peerIdentityPrefix$peerUserId', identityKeyB64);
      return Uint8List.fromList(base64Decode(identityKeyB64));
    } catch (e) {
      debugPrint('[Crypto] Failed to fetch peer identity key: $e');
      return null;
    }
  }

  /// Get the local identity public key bytes.
  Future<Uint8List?> getIdentityPublicKey() async {
    if (_identityKeyPair == null) return null;
    final pub = await _identityKeyPair!.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
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

    // Generate one-time prekeys and persist private keys
    final store = SecureKeyStore.instance;
    final otps = <Map<String, dynamic>>[];
    for (var i = 0; i < 10; i++) {
      final otpPair = await _x25519.newKeyPair();
      final otpPub = await otpPair.extractPublicKey();
      final otpPrivBytes = await (otpPair as SimpleKeyPairData)
          .extractPrivateKeyBytes();

      // Persist OTP key pair keyed by key_id for lookup during decryption
      final pubB64 = base64Encode(otpPub.bytes);
      await store.write(
        '$_otpPrivatePrefix$i',
        jsonEncode({'private': base64Encode(otpPrivBytes), 'public': pubB64}),
      );

      otps.add({'key_id': i, 'public_key': pubB64});
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

    // Cache peer identity key for safety number generation
    final peerStore = SecureKeyStore.instance;
    await peerStore.write(
      '$_peerIdentityPrefix$peerUserId',
      data['identity_key'] as String,
    );

    // Extract one-time prekey if the server provided one (4-DH)
    SimplePublicKey? bobOneTimePrekey;
    int? otpKeyId;
    final otpData = data['one_time_prekey'] as Map<String, dynamic>?;
    if (otpData != null) {
      final otpPubB64 = otpData['public_key'] as String?;
      otpKeyId = otpData['key_id'] as int?;
      if (otpPubB64 != null) {
        bobOneTimePrekey = SimplePublicKey(
          base64Decode(otpPubB64),
          type: KeyPairType.x25519,
        );
      }
    }

    // Perform X3DH as Alice (initiator) -- 4-DH with OTP if available
    final x3dhResult = await X3DH.initiate(
      aliceIdentity: _identityKeyPair!,
      bobIdentityKey: bobIdentityKey,
      bobSignedPrekey: bobSignedPrekey,
      bobOneTimePrekey: bobOneTimePrekey,
    );

    // Track which OTP key ID was used so we can include it in the wire format
    _lastOtpKeyId = otpKeyId;

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
  // V1: [0xEC, 0x01] || identity(32) || ephemeral(32) || session_wire (no OTP)
  // V2: [0xEC, 0x02] || identity(32) || ephemeral(32) || otp_key_id(4 LE) || session_wire (with OTP)
  static const _initialMsgMagicV1 = [0xEC, 0x01];
  static const _initialMsgMagicV2 = [0xEC, 0x02];

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
      final idPub = (await _identityKeyPair!.extractPublicKey()).bytes;
      final ephPub = _lastX3dhResult!.ephemeralPublic.bytes;

      if (_lastOtpKeyId != null) {
        // V2 format: includes OTP key ID so Bob can look up the right private key
        finalWire = Uint8List(2 + 32 + 32 + 4 + wire.length);
        finalWire[0] = _initialMsgMagicV2[0];
        finalWire[1] = _initialMsgMagicV2[1];
        finalWire.setRange(2, 34, Uint8List.fromList(idPub));
        finalWire.setRange(34, 66, Uint8List.fromList(ephPub));
        final bd = ByteData.sublistView(finalWire);
        bd.setInt32(66, _lastOtpKeyId!, Endian.little);
        finalWire.setRange(70, finalWire.length, wire);
      } else {
        // V1 format: no OTP used (3-DH)
        finalWire = Uint8List(2 + 32 + 32 + wire.length);
        finalWire[0] = _initialMsgMagicV1[0];
        finalWire[1] = _initialMsgMagicV1[1];
        finalWire.setRange(2, 34, Uint8List.fromList(idPub));
        finalWire.setRange(34, 66, Uint8List.fromList(ephPub));
        finalWire.setRange(66, finalWire.length, wire);
      }

      _lastX3dhResult = null;
      _lastOtpKeyId = null;
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

    // Check for initial message magic prefix (V1 or V2)
    final isV1 =
        fullWire.length > 66 &&
        fullWire[0] == _initialMsgMagicV1[0] &&
        fullWire[1] == _initialMsgMagicV1[1];
    final isV2 =
        fullWire.length > 70 &&
        fullWire[0] == _initialMsgMagicV2[0] &&
        fullWire[1] == _initialMsgMagicV2[1];
    if ((isV1 || isV2) && !_sessions.containsKey(peerUserId)) {
      // This is an initial message -- establish session as Bob
      final aliceIdentityBytes = fullWire.sublist(2, 34);
      final aliceIdentityPub = SimplePublicKey(
        aliceIdentityBytes,
        type: KeyPairType.x25519,
      );
      final aliceEphemeralPub = SimplePublicKey(
        fullWire.sublist(34, 66),
        type: KeyPairType.x25519,
      );

      // V2 includes a 4-byte OTP key ID after the ephemeral key
      SimpleKeyPair? bobOtp;
      final Uint8List sessionWire;
      if (isV2) {
        final bd = ByteData.sublistView(fullWire);
        final otpKeyId = bd.getInt32(66, Endian.little);
        sessionWire = fullWire.sublist(70);
        // Look up the OTP key pair by key ID
        bobOtp = await _loadOtpPrivateKey(otpKeyId);
        if (bobOtp != null) {
          debugPrint('[Crypto] Using OTP key_id=$otpKeyId for 4-DH');
        } else {
          debugPrint(
            '[Crypto] OTP key_id=$otpKeyId not found -- 3-DH fallback',
          );
        }
      } else {
        sessionWire = fullWire.sublist(66);
      }

      // Cache peer identity key for safety number generation
      final peerStore = SecureKeyStore.instance;
      await peerStore.write(
        '$_peerIdentityPrefix$peerUserId',
        base64Encode(aliceIdentityBytes),
      );

      // Compute X3DH as Bob (responder)
      if (_signedPrekeyPair == null) await init();

      // Try current signed prekey first, then fall back to previous
      // in case the peer fetched the old bundle before rotation.
      Uint8List sharedSecret;
      SimpleKeyPair prekeyToUse;
      try {
        sharedSecret = await X3DH.respond(
          bobIdentity: _identityKeyPair!,
          bobSignedPrekey: _signedPrekeyPair!,
          bobOneTimePrekey: bobOtp,
          aliceIdentityKey: aliceIdentityPub,
          aliceEphemeralKey: aliceEphemeralPub,
        );
        prekeyToUse = _signedPrekeyPair!;
      } catch (_) {
        // Try previous signed prekey
        final prevPrekey = await _loadPreviousSignedPrekey();
        if (prevPrekey == null) rethrow;
        sharedSecret = await X3DH.respond(
          bobIdentity: _identityKeyPair!,
          bobSignedPrekey: prevPrekey,
          bobOneTimePrekey: bobOtp,
          aliceIdentityKey: aliceIdentityPub,
          aliceEphemeralKey: aliceEphemeralPub,
        );
        prekeyToUse = prevPrekey;
      }

      // Initialize Double Ratchet as Bob
      final session = await SignalSession.initBob(sharedSecret, prekeyToUse);

      // Decrypt the actual message
      final plainBytes = await session.decrypt(sessionWire);
      _sessions[peerUserId] = session;
      await _saveSession(peerUserId, session);

      // Consume the OTP -- delete after successful use (one-time)
      if (bobOtp != null && isV2) {
        final bd2 = ByteData.sublistView(fullWire);
        final consumedId = bd2.getInt32(66, Endian.little);
        await _deleteOtpPrivateKey(consumedId);
      }

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
      if (key.startsWith(_sessionPrefix) || key.startsWith(_otpPrivatePrefix)) {
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

  /// Load the previous signed prekey pair from secure storage.
  ///
  /// Returns null if no previous prekey is stored.
  Future<SimpleKeyPair?> _loadPreviousSignedPrekey() async {
    final store = SecureKeyStore.instance;
    final prevPriv = await store.read(_signedPrekeyPreviousPref);
    final prevPub = await store.read(_signedPrekeyPreviousPubPref);
    if (prevPriv == null || prevPub == null) return null;

    return SimpleKeyPairData(
      base64Decode(prevPriv),
      publicKey: SimplePublicKey(
        base64Decode(prevPub),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
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
      if (key.startsWith(_sessionPrefix) ||
          key.startsWith(_peerIdentityPrefix) ||
          key.startsWith(_otpPrivatePrefix)) {
        await store.delete(key);
      }
    }
  }

  // -----------------------------------------------------------------------
  // OTP private key persistence
  // -----------------------------------------------------------------------

  /// Load a one-time prekey private key by key_id from secure storage.
  Future<SimpleKeyPair?> _loadOtpPrivateKey(int keyId) async {
    final store = SecureKeyStore.instance;
    final raw = await store.read('$_otpPrivatePrefix$keyId');
    if (raw == null) return null;

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final privBytes = base64Decode(data['private'] as String);
      final pubBytes = base64Decode(data['public'] as String);
      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    } catch (e) {
      debugPrint('[Crypto] Failed to load OTP key_id=$keyId: $e');
      return null;
    }
  }

  /// Delete a consumed one-time prekey from secure storage.
  Future<void> _deleteOtpPrivateKey(int keyId) async {
    final store = SecureKeyStore.instance;
    await store.delete('$_otpPrivatePrefix$keyId');
    debugPrint('[Crypto] Consumed and deleted OTP key_id=$keyId');
  }

  // -----------------------------------------------------------------------
  // Group key wrapping: encrypt/decrypt a symmetric key for a specific user
  // -----------------------------------------------------------------------

  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Encrypt [plaintext] for a specific recipient using their X25519 identity
  /// public key. Uses ECDH + HKDF + AES-256-GCM.
  ///
  /// Returns base64(ephemeral_pub(32) || nonce(12) || ciphertext || tag(16)).
  Future<String> encryptForUser(
    Uint8List plaintext,
    Uint8List recipientPublicKeyBytes,
  ) async {
    if (_identityKeyPair == null) await init();

    // Generate ephemeral key pair for this encryption
    final ephemeral = await _x25519.newKeyPair();
    final ephPub = await ephemeral.extractPublicKey();

    // ECDH with recipient's identity public key
    final recipientPub = SimplePublicKey(
      recipientPublicKeyBytes,
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: recipientPub,
    );
    final sharedBytes = await shared.extractBytes();

    // Derive AES key via HKDF
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKeyData(sharedBytes),
      nonce: Uint8List(32),
      info: 'EchoGroupKeyWrap'.codeUnits,
    );
    final aesKey = SecretKey(await derived.extractBytes());

    // Encrypt
    final box = await _aesGcm.encrypt(plaintext, secretKey: aesKey);

    // Wire: ephemeral_pub(32) || nonce(12) || ciphertext || tag(16)
    final nonce = Uint8List.fromList(box.nonce);
    final ct = Uint8List.fromList(box.cipherText);
    final mac = Uint8List.fromList(box.mac.bytes);
    final wire = Uint8List(32 + 12 + ct.length + 16);
    wire.setRange(0, 32, Uint8List.fromList(ephPub.bytes));
    wire.setRange(32, 44, nonce);
    wire.setRange(44, 44 + ct.length, ct);
    wire.setRange(44 + ct.length, wire.length, mac);

    return base64Encode(wire);
  }

  /// Decrypt data that was encrypted with [encryptForUser] using our identity
  /// private key.
  ///
  /// [ciphertextB64] is base64(ephemeral_pub(32) || nonce(12) || ct || tag(16)).
  Future<Uint8List> decryptFromUser(String ciphertextB64) async {
    if (_identityKeyPair == null) await init();

    final wire = Uint8List.fromList(base64Decode(ciphertextB64));
    if (wire.length < 32 + 12 + 16) {
      throw FormatException(
        'encryptForUser ciphertext too short: ${wire.length} bytes',
      );
    }

    final ephPub = SimplePublicKey(
      wire.sublist(0, 32),
      type: KeyPairType.x25519,
    );
    final nonce = wire.sublist(32, 44);
    final ct = wire.sublist(44, wire.length - 16);
    final mac = Mac(wire.sublist(wire.length - 16));

    // ECDH with the ephemeral key
    final shared = await _x25519.sharedSecretKey(
      keyPair: _identityKeyPair!,
      remotePublicKey: ephPub,
    );
    final sharedBytes = await shared.extractBytes();

    // Derive AES key via HKDF (same parameters as encrypt)
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKeyData(sharedBytes),
      nonce: Uint8List(32),
      info: 'EchoGroupKeyWrap'.codeUnits,
    );
    final aesKey = SecretKey(await derived.extractBytes());

    // Decrypt
    final box = SecretBox(ct, nonce: nonce, mac: mac);
    final plaintext = await _aesGcm.decrypt(box, secretKey: aesKey);
    return Uint8List.fromList(plaintext);
  }
}
