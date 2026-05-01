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

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log_service.dart';
import 'safety_number_service.dart';
import 'secure_key_store.dart';
import 'session_cache.dart';
import 'signal_session.dart';
import 'signal_x3dh.dart';

/// Thrown by [CryptoService.getOrCreateSession] when the peer's identity
/// key on the server differs from the key we previously trusted (TOFU
/// violation). Callers must surface this via the safety-number /
/// "trust new key" UI before establishing a new session — silently
/// overwriting the trusted key would let an attacker who has taken over
/// the server impersonate the peer (#580).
class IdentityKeyChangedException implements Exception {
  /// Peer whose identity key changed.
  final String peerUserId;

  /// Previously-trusted identity key (base64), or `null` if for some
  /// reason the old value could not be read back.
  final String? oldIdentityKeyB64;

  /// New identity key returned by the server (base64).
  final String newIdentityKeyB64;

  const IdentityKeyChangedException({
    required this.peerUserId,
    required this.oldIdentityKeyB64,
    required this.newIdentityKeyB64,
  });

  @override
  String toString() =>
      'IdentityKeyChangedException(peer=$peerUserId): trusted identity key '
      'changed; user must verify safety number or explicitly accept new key';
}

/// Thrown by [CryptoService.uploadKeys] when the server rejects the upload
/// because the identity-key fingerprint we presented for this device does
/// not match what is on file (#664). The body carries the device_id and the
/// expected/actual fingerprints (base64) so the UI can drive a typed reset
/// flow instead of parsing English error strings.
class IdentityKeyConflictException implements Exception {
  /// Device id reported by the server. Falls back to the local device id when
  /// the server returned a legacy (string-only) 409 without a JSON body.
  final int deviceId;

  /// Server-side fingerprint (base64) -- the value we'd need to match. Null
  /// when the server returned a legacy body.
  final String? expectedFingerprint;

  /// Fingerprint we sent (base64). Null when no body was returned.
  final String? actualFingerprint;

  const IdentityKeyConflictException({
    required this.deviceId,
    this.expectedFingerprint,
    this.actualFingerprint,
  });

  @override
  String toString() =>
      'IdentityKeyConflictException(device=$deviceId, '
      'expected=${expectedFingerprint ?? "?"}, '
      'actual=${actualFingerprint ?? "?"})';
}

/// Thrown by [CryptoService.decryptMessage] when an initial X3DH wire
/// failed to authenticate (AES-GCM tag check). The receiver's keys on the
/// server are likely stale; the service schedules an `uploadKeys()` to heal
/// the bundle so the next message from the same peer can decrypt (#662).
class InitialDecryptFailedException implements Exception {
  final String peerUserId;
  const InitialDecryptFailedException(this.peerUserId);

  @override
  String toString() =>
      'InitialDecryptFailedException(peer=$peerUserId): initial X3DH wire '
      'failed AES-GCM auth; uploaded fresh keys to heal stale bundle';
}

class CryptoService {
  static const _deviceIdPref = 'echo_device_id';
  static const _identityKeyPref = 'echo_identity_key';
  static const _contentTypeHeader = 'Content-Type';
  static const _applicationJson = 'application/json';
  static const _identityPubKeyPref = 'echo_identity_pub_key';
  static const _signingKeyPref = 'echo_signing_key';
  static const _signingPubKeyPref = 'echo_signing_pub_key';
  static const _signedPrekeyPref = 'echo_signed_prekey';
  static const _signedPrekeyPubPref = 'echo_signed_prekey_pub';
  static const _sessionPrefix = 'echo_signal_session_';
  static const _peerIdentityPrefix = 'echo_peer_identity_';
  static const _peerIdentityChangedPrefix = 'echo_peer_identity_changed_';
  static const _otpPrivatePrefix = 'echo_otp_private_';
  static const _signedPrekeyCreatedAtPref = 'echo_signed_prekey_created_at';
  static const _signedPrekeyPreviousPref = 'echo_signed_prekey_previous';
  static const _signedPrekeyPreviousPubPref = 'echo_signed_prekey_previous_pub';
  static const _otpNextIdPref = 'echo_otp_next_id';

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

  /// Unique device identifier for this installation. Generated once on first
  /// launch and persisted in secure storage. Used for multi-device key
  /// management -- each device uploads its own key bundle with this ID so the
  /// server can distinguish devices for the same user.
  int _deviceId = 0;

  /// The device ID for this installation.
  int get deviceId => _deviceId;

  SimpleKeyPair? _identityKeyPair;
  SimpleKeyPair? _signedPrekeyPair;
  SimpleKeyPair? _signingKeyPair;

  /// Sessions persist on disk via [_saveSession]; eviction is non-destructive
  /// and the cache reloads from secure storage on miss (#343).
  final SessionCache _sessions = SessionCache();
  bool _keysAreFresh = false;
  bool _keysWereRegenerated = false;
  bool _needsOtpReplenishment = false;

  /// Per-peer async lock to serialize encrypt/decrypt operations.
  /// Prevents interleaved async ops from corrupting session chain state.
  final Map<String, Completer<void>> _sessionLocks = {};

  /// Cache of per-user device bundles with TTL for multi-device encryption.
  /// Key: userId, Value: (bundles, fetchedAt)
  final Map<String, (List<Map<String, dynamic>>, DateTime)> _bundleCache = {};
  static const _bundleCacheTtl = Duration(minutes: 5);

  final _x25519 = X25519();
  final _ed25519 = Ed25519();

  CryptoService({required this.serverUrl});

  /// Serialize async operations on a per-peer session to prevent interleaved
  /// encrypt/decrypt calls from corrupting the chain state.
  Future<T> _withSessionLock<T>(
    String peerId,
    Future<T> Function() operation,
  ) async {
    while (_sessionLocks.containsKey(peerId)) {
      await _sessionLocks[peerId]!.future;
    }
    final completer = Completer<void>();
    _sessionLocks[peerId] = completer;
    try {
      return await operation();
    } finally {
      _sessionLocks.remove(peerId);
      completer.complete();
    }
  }

  void setToken(String token) {
    _token = token;
  }

  bool get isInitialized => _identityKeyPair != null;
  bool get keysAreFresh => _keysAreFresh;

  /// True if identity keys were regenerated (not restored from storage).
  /// This means old encrypted messages cannot be decrypted.
  bool get keysWereRegenerated => _keysWereRegenerated;

  /// Migrate crypto keys from SharedPreferences to SecureKeyStore.
  ///
  /// Checks SharedPreferences for each crypto key; if found, copies it to
  /// secure storage and deletes from SharedPreferences. Session keys (prefixed
  /// with [_sessionPrefix]), OTP private keys, and peer identity keys are also
  /// migrated.
  ///
  /// A completion flag is written to secure storage after all keys are
  /// successfully moved. If the flag already exists, migration is skipped.
  /// Each write is guarded: if [SecureKeyStore.write] throws (e.g. keyring
  /// unavailable), the key is left in SharedPreferences so the next launch can
  /// retry the migration instead of losing the data.
  Future<void> _migrateFromSharedPreferences() async {
    final store = SecureKeyStore.instance;

    // Skip if migration was already completed.
    final migrated = await store.read('_crypto_migration_complete');
    if (migrated == 'true') return;

    final prefs = await SharedPreferences.getInstance();
    var allSucceeded = true;

    // On web, skip removing keys from SharedPreferences after copying to
    // secure storage. SecureKeyStore on web uses Web Crypto API encryption
    // which can fail to decrypt after page refresh in some browsers, so
    // SharedPreferences (plain localStorage) is the reliable fallback.
    final removeFromPrefs = !kIsWeb;

    // Migrate identity + signing + signed prekey (named keys)
    for (final key in _allCryptoKeys) {
      final value = prefs.getString(key);
      if (value != null) {
        try {
          await store.write(key, value);
          if (removeFromPrefs) await prefs.remove(key);
          debugPrint(
            '[Crypto] Migrated $key from SharedPreferences to '
            'secure storage',
          );
        } catch (e) {
          allSucceeded = false;
          debugPrint(
            '[Crypto] Migration of $key failed (keeping in SharedPreferences '
            'for next attempt): $e',
          );
        }
      }
    }

    // Migrate prefixed keys: sessions, OTP privates, peer identities
    for (final key in prefs.getKeys()) {
      final isPrefixed =
          key.startsWith(_sessionPrefix) ||
          key.startsWith(_otpPrivatePrefix) ||
          key.startsWith(_peerIdentityPrefix) ||
          key.startsWith(_peerIdentityChangedPrefix);
      if (isPrefixed) {
        final value = prefs.getString(key);
        if (value != null) {
          try {
            await store.write(key, value);
            if (removeFromPrefs) await prefs.remove(key);
            debugPrint('[Crypto] Migrated $key to secure storage');
          } catch (e) {
            allSucceeded = false;
            debugPrint(
              '[Crypto] Migration of $key failed '
              '(keeping in SharedPreferences): $e',
            );
          }
        }
      }
    }

    // Also migrate device ID and OTP next ID
    for (final key in [_deviceIdPref, _otpNextIdPref]) {
      final value = prefs.getString(key);
      if (value != null) {
        try {
          await store.write(key, value);
          if (removeFromPrefs) await prefs.remove(key);
        } catch (e) {
          allSucceeded = false;
        }
      }
    }

    if (allSucceeded) {
      await store.write('_crypto_migration_complete', 'true');
      debugPrint('[Crypto] Migration complete -- all keys in secure storage');
    } else {
      debugPrint('[Crypto] Migration incomplete -- will retry on next launch');
    }
  }

  /// Restore identity, signing, and signed prekey from secure storage.
  ///
  /// [readKey] is used to read values, allowing callers to inject a fallback
  /// strategy (e.g. SharedPreferences on web) when SecureKeyStore fails.
  Future<void> _restoreKeysFromStorage(
    SecureKeyStore store,
    String storedPrivate, {
    Future<String?> Function(String key)? readKey,
  }) async {
    Future<String?> read(String key) async =>
        readKey != null ? readKey(key) : store.read(key);

    final privateBytes = base64Decode(storedPrivate);
    final publicBytes = base64Decode((await read(_identityPubKeyPref))!);
    _identityKeyPair = SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );

    // Restore Ed25519 signing key pair
    final sigPriv = await read(_signingKeyPref);
    final sigPub = await read(_signingPubKeyPref);
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
      _signingKeyPair = await _ed25519.newKeyPair();
      await _saveSigningKey(store);
      _keysAreFresh = true;
    }

    // Restore signed prekey pair
    final spkPriv = await read(_signedPrekeyPref);
    final spkPub = await read(_signedPrekeyPubPref);
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
      _signedPrekeyPair = await _x25519.newKeyPair();
      await _saveSignedPrekey(store);
      _keysAreFresh = true;
    }

    // Always mark identity bundle for upload so the server has the
    // current bundle.
    _keysAreFresh = true;
    _needsOtpReplenishment = false;

    await _loadSessions(store);
    await _rotateSignedPrekeyIfNeeded(store);
  }

  /// Initialize: load or generate identity key pair, signing key, and signed prekey.
  Future<void> init() async {
    try {
      // Run migration before anything else -- moves keys from SharedPreferences
      // into platform-secure storage if they exist there from a previous version.
      await _migrateFromSharedPreferences();

      final store = SecureKeyStore.instance;

      // On web, SecureKeyStore encrypts values with Web Crypto API. If the
      // encryption key is lost (browser cleared storage, incognito, etc.),
      // reads return null even though the keys were previously stored. Fall
      // back to SharedPreferences which uses plain localStorage.
      final SharedPreferences? webFallbackPrefs = kIsWeb
          ? await SharedPreferences.getInstance()
          : null;

      Future<String?> readWithFallback(String key) async {
        final value = await store.read(key);
        if (value != null) return value;
        return webFallbackPrefs?.getString(key);
      }

      // Load or generate a unique device ID for this installation.
      final storedDeviceId = await readWithFallback(_deviceIdPref);
      await _loadOrGenerateDeviceId(store, storedDeviceId);

      final storedPrivate = await readWithFallback(_identityKeyPref);

      if (storedPrivate != null) {
        await _restoreKeysFromStorage(
          store,
          storedPrivate,
          readKey: readWithFallback,
        );
      } else {
        await _generateFreshKeys(store, isFirstInstall: storedDeviceId == null);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Load an existing device ID from [storedDeviceId] or generate a new one.
  Future<void> _loadOrGenerateDeviceId(
    SecureKeyStore store,
    String? storedDeviceId,
  ) async {
    if (storedDeviceId != null) {
      _deviceId = int.tryParse(storedDeviceId) ?? 0;
    } else {
      // Generate a random positive device ID (1..2^30) to avoid collision
      // with legacy device_id=0 from single-device era.
      _deviceId = Random.secure().nextInt(1 << 30) + 1;
      await store.write(_deviceIdPref, _deviceId.toString());
      debugPrint('[Crypto] Generated new device_id: $_deviceId');
    }
  }

  /// Generate all identity/signing/prekey key pairs for a fresh installation
  /// (no stored private key found). Purges any stale sessions that reference
  /// the old keys.
  Future<void> _generateFreshKeys(
    SecureKeyStore store, {
    required bool isFirstInstall,
  }) async {
    // Only flag as "regenerated" when prior keys existed (device ID was
    // already assigned). On a true first install there is nothing to
    // regenerate, so suppress the misleading warning.
    _keysWereRegenerated = !isFirstInstall;
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
    _needsOtpReplenishment = true; // Fresh install needs OTP keys

    // Purge any stale sessions from storage — they reference the old keys.
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith(_sessionPrefix)) {
        await store.delete(key);
      }
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
  /// Uses Trust-On-First-Use (TOFU): the first-seen key is trusted and
  /// persisted. If a later fetch returns a different key, a warning is logged
  /// and a `_peerIdentityChangedPrefix` flag is persisted for the peer.
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

      await _storePeerIdentityKeyTofu(peerUserId, identityKeyB64);
      return Uint8List.fromList(base64Decode(identityKeyB64));
    } catch (e) {
      debugPrint('[Crypto] Failed to fetch peer identity key: $e');
      return null;
    }
  }

  /// Store a peer's identity key with Trust-On-First-Use (TOFU) semantics.
  ///
  /// - First encounter: stores the key.
  /// - Same key: no-op.
  /// - Different key: logs a warning via [DebugLogService] and persists a
  ///   flag (`_peerIdentityChangedPrefix + peerId`) for UI to surface later.
  ///   The new key is stored so future sessions use the latest key.
  Future<void> _storePeerIdentityKeyTofu(
    String peerUserId,
    String newKeyB64,
  ) async {
    final store = SecureKeyStore.instance;
    final storeKey = '$_peerIdentityPrefix$peerUserId';
    final existing = await store.read(storeKey);

    if (existing != null && existing != newKeyB64) {
      DebugLogService.instance.log(
        LogLevel.warning,
        'Crypto',
        'TOFU: identity key changed for peer $peerUserId -- '
            'possible key reset or MITM. Old prefix: '
            '${existing.substring(0, min(8, existing.length))}..., '
            'new prefix: '
            '${newKeyB64.substring(0, min(8, newKeyB64.length))}...',
      );
      debugPrint('[Crypto] WARNING: peer $peerUserId identity key changed!');
      // Persist a flag so the UI can surface a warning banner later.
      await store.write(
        '$_peerIdentityChangedPrefix$peerUserId',
        DateTime.now().toIso8601String(),
      );
    }

    // Store the (possibly new) key so future sessions use the latest.
    await store.write(storeKey, newKeyB64);
  }

  /// Check whether a peer's identity key has changed since first contact.
  Future<bool> hasPeerIdentityKeyChanged(String peerUserId) async {
    final store = SecureKeyStore.instance;
    final flag = await store.read('$_peerIdentityChangedPrefix$peerUserId');
    return flag != null;
  }

  /// Acknowledge a peer identity key change (clears the flag).
  Future<void> acknowledgePeerIdentityKeyChange(String peerUserId) async {
    final store = SecureKeyStore.instance;
    await store.delete('$_peerIdentityChangedPrefix$peerUserId');
  }

  /// Explicitly trust the peer's new identity key after the user has
  /// reviewed (or chosen to skip reviewing) the safety number.
  ///
  /// This is the explicit counterpart to the previously-silent overwrite
  /// in TOFU: it clears the change flag, persists [newIdentityKeyB64] (or,
  /// if `null`, leaves whatever was last written by TOFU in place), and
  /// drops any cached/persisted Signal session for the peer so the next
  /// outbound message triggers a fresh X3DH against the trusted key.
  /// (#580)
  Future<void> acceptIdentityKeyChange(
    String peerUserId, {
    String? newIdentityKeyB64,
  }) async {
    final store = SecureKeyStore.instance;
    if (newIdentityKeyB64 != null) {
      await store.write('$_peerIdentityPrefix$peerUserId', newIdentityKeyB64);
    }
    await store.delete('$_peerIdentityChangedPrefix$peerUserId');
    // Drop any cached/persisted session keyed to the old identity so the
    // next send re-runs X3DH against the freshly-trusted key.
    _sessions.remove(peerUserId);
    await store.delete('$_sessionPrefix$peerUserId');
  }

  /// Compute the safety-number fingerprint between this device and
  /// [peerUserId], or `null` if either identity key is unavailable.
  ///
  /// Deterministic regardless of which side calls it (keys are sorted
  /// before hashing). See [SafetyNumberService] for the spec.
  Future<String?> safetyNumberFor(String peerUserId) async {
    final myKey = await getIdentityPublicKey();
    if (myKey == null) return null;
    final store = SecureKeyStore.instance;
    final peerB64 = await store.read('$_peerIdentityPrefix$peerUserId');
    if (peerB64 == null) return null;
    final peerKey = Uint8List.fromList(base64Decode(peerB64));
    return SafetyNumberService.generate(myKey, peerKey);
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

  /// Peers whose sessions were corrupted in storage.  We do not silently
  /// create new outgoing sessions for these peers — the caller must decide
  /// whether to force-reset.
  final Set<String> _corruptedSessions = {};

  /// Whether a peer's session is corrupted and needs manual repair.
  bool hasCorruptedSession(String peerUserId) =>
      _corruptedSessions.contains(peerUserId);

  /// Load persisted Signal sessions from secure storage.
  ///
  /// Handles both legacy format (`echo_signal_session_<userId>`) and
  /// multi-device format (`echo_signal_session_<userId>:<deviceId>`).
  Future<void> _loadSessions(SecureKeyStore store) async {
    _sessions.clear();
    _corruptedSessions.clear();
    final allEntries = await store.readAll();
    for (final entry in allEntries.entries) {
      if (entry.key.startsWith(_sessionPrefix) &&
          !entry.key.contains('corrupt_')) {
        final peerId = entry.key.substring(_sessionPrefix.length);
        try {
          final json = jsonDecode(entry.value) as Map<String, dynamic>;
          _sessions.put(peerId, SignalSession.fromJson(json));
        } catch (e) {
          debugPrint('[Crypto] Quarantining corrupted session for $peerId: $e');
          // Quarantine instead of deleting — preserve data for potential
          // manual recovery and prevent getOrCreateSession from silently
          // creating an incompatible new session.
          await store.write('${_sessionPrefix}corrupt_$peerId', entry.value);
          await store.delete(entry.key);
          _corruptedSessions.add(peerId);
        }
      }
    }
    DebugLogService.instance.log(
      LogLevel.info,
      'Crypto',
      'Loaded ${_sessions.length} session(s) from storage on init',
    );
  }

  /// Force-reset a corrupted or broken session with a peer.
  ///
  /// Clears the quarantined session and creates a new outgoing session.
  /// The first message sent will be an initial X3DH message which the peer
  /// will accept (replacing their stale session).
  Future<void> forceResetSession(String peerUserId) async {
    final store = SecureKeyStore.instance;
    await store.delete('${_sessionPrefix}corrupt_$peerUserId');
    _corruptedSessions.remove(peerUserId);
    _sessions.remove(peerUserId);
    await store.delete('$_sessionPrefix$peerUserId');
  }

  /// Persist a Signal session to secure storage.
  Future<void> _saveSession(String peerId, SignalSession session) async {
    final store = SecureKeyStore.instance;
    final json = await session.toJson();
    await store.write('$_sessionPrefix$peerId', jsonEncode(json));
  }

  /// On cache miss, attempt to reload a single session from secure storage
  /// before falling back to X3DH (#343 -- non-destructive eviction).
  /// Returns null if no persisted session exists or it cannot be parsed.
  Future<SignalSession?> _reloadSession(String key) async {
    try {
      final store = SecureKeyStore.instance;
      final raw = await store.read('$_sessionPrefix$key');
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final session = SignalSession.fromJson(json);
      _sessions.put(key, session);
      return session;
    } catch (e) {
      debugPrint('[Crypto] Failed to reload session for $key: $e');
      return null;
    }
  }

  /// Human-readable label for the current platform, sent to the server as part
  /// of the prekey bundle so the device-management UI can display "iOS",
  /// "Linux", etc. Returns `null` on unrecognised platforms so the server
  /// falls back to its stored value.
  String? _platformString() {
    if (kIsWeb) return 'Web';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return null;
  }

  /// Upload our public keys to the server as a PreKey bundle.
  ///
  /// Includes:
  /// - X25519 identity key
  /// - Ed25519 signing key (for prekey signature verification)
  /// - Signed prekey with real Ed25519 signature
  /// - One-time prekeys (only when replenishment is needed)
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

    // Only generate new OTP keys when replenishment is actually needed
    // (fresh install, key regeneration, or server count is low).
    // On normal restart, we keep existing OTP private keys intact to avoid
    // the key-ID collision bug where the server holds old public keys but
    // the client overwrites local private keys with new material.
    final otps = <Map<String, dynamic>>[];
    if (_needsOtpReplenishment) {
      await _generateAndPersistOtpKeys(otps);
      _needsOtpReplenishment = false;
    }

    final payload = <String, dynamic>{
      'identity_key': pubKeyB64,
      'signing_key': signingPubB64,
      'signed_prekey': spkPubB64,
      'signed_prekey_signature': sigB64,
      'signed_prekey_id': 1,
      'one_time_prekeys': otps,
      'device_id': _deviceId,
    };
    final platform = _platformString();
    if (platform != null) {
      payload['platform'] = platform;
    }
    final body = jsonEncode(payload);

    final response = await http.post(
      Uri.parse('$serverUrl/api/keys/upload'),
      headers: {
        _contentTypeHeader: _applicationJson,
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );

    if (response.statusCode == 409) {
      // Server returns a structured `identity_key_conflict` envelope (#664)
      // with `device_id`, `expected_fingerprint`, `actual_fingerprint`. Older
      // servers emit a plain `{"error": "..."}` body; tolerate both.
      int conflictDeviceId = _deviceId;
      String? expected;
      String? actual;
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          if (body['code'] == 'identity_key_conflict') {
            conflictDeviceId =
                (body['device_id'] as num?)?.toInt() ?? _deviceId;
            expected = body['expected_fingerprint'] as String?;
            actual = body['actual_fingerprint'] as String?;
          }
        }
      } catch (_) {
        // Legacy server response -- fall through with defaults.
      }
      throw IdentityKeyConflictException(
        deviceId: conflictDeviceId,
        expectedFingerprint: expected,
        actualFingerprint: actual,
      );
    }

    if (response.statusCode != 201) {
      throw Exception(
        'Failed to upload keys: HTTP ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Generate 10 new OTP key pairs with monotonically increasing IDs.
  ///
  /// Uses a persisted counter ([_otpNextIdPref]) so that IDs never collide
  /// with previously uploaded keys. This prevents the critical bug where
  /// re-using IDs 0-9 on every upload causes the server to keep old public
  /// keys (via ON CONFLICT DO NOTHING) while the client overwrites local
  /// private keys with new material.
  Future<void> _generateAndPersistOtpKeys(
    List<Map<String, dynamic>> otps,
  ) async {
    final store = SecureKeyStore.instance;

    // Read persisted counter (default 0 for first-ever upload)
    int nextId = 0;
    final storedNextId = await store.read(_otpNextIdPref);
    if (storedNextId != null) {
      nextId = int.tryParse(storedNextId) ?? 0;
    }

    for (var i = 0; i < 10; i++) {
      final keyId = nextId + i;
      final otpPair = await _x25519.newKeyPair();
      final otpPub = await otpPair.extractPublicKey();
      final otpPrivBytes = await (otpPair as SimpleKeyPairData)
          .extractPrivateKeyBytes();

      final pubB64 = base64Encode(otpPub.bytes);
      await store.write(
        '$_otpPrivatePrefix$keyId',
        jsonEncode({'private': base64Encode(otpPrivBytes), 'public': pubB64}),
      );

      otps.add({'key_id': keyId, 'public_key': pubB64});
    }

    // Persist the next counter value for future uploads
    await store.write(_otpNextIdPref, '${nextId + 10}');
    debugPrint('[Crypto] Generated OTP keys $nextId..${nextId + 9}');
  }

  /// Check the server's remaining unused OTP count and replenish if low.
  Future<void> checkAndReplenishOtpKeys() async {
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/keys/otp-count?device_id=$_deviceId'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final count = data['count'] as int? ?? 0;
        if (count < 5) {
          debugPrint('[Crypto] OTP count low ($count), replenishing...');
          final otps = <Map<String, dynamic>>[];
          await _generateAndPersistOtpKeys(otps);
          // Upload just the new OTPs (identity bundle already on server)
          await _uploadOtpBatch(otps);
        }
      }
    } catch (e) {
      debugPrint('[Crypto] OTP replenishment check failed: $e');
    }
  }

  /// Upload a batch of OTP public keys to the server.
  Future<void> _uploadOtpBatch(List<Map<String, dynamic>> otps) async {
    if (otps.isEmpty) return;
    if (_identityKeyPair == null) return;

    final publicKey = await _identityKeyPair!.extractPublicKey();
    final spkPub = await _signedPrekeyPair!.extractPublicKey();
    final signature = await _ed25519.sign(
      spkPub.bytes,
      keyPair: _signingKeyPair!,
    );
    final signingPub = await _signingKeyPair!.extractPublicKey();

    final body = jsonEncode({
      'identity_key': base64Encode(publicKey.bytes),
      'signing_key': base64Encode(signingPub.bytes),
      'signed_prekey': base64Encode(spkPub.bytes),
      'signed_prekey_signature': base64Encode(signature.bytes),
      'signed_prekey_id': 1,
      'one_time_prekeys': otps,
      'device_id': _deviceId,
    });

    final response = await http.post(
      Uri.parse('$serverUrl/api/keys/upload'),
      headers: {
        _contentTypeHeader: _applicationJson,
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );

    if (response.statusCode == 201) {
      debugPrint('[Crypto] Uploaded ${otps.length} new OTP keys');
    }
  }

  /// Get or create a Signal session with a peer.
  ///
  /// If a session already exists in memory or was loaded from storage, returns
  /// it with both X3DH fields null (no initial-message header needed).
  /// Otherwise, fetches the peer's prekey bundle from the server, performs X3DH
  /// to establish a shared secret, and initializes a new Double Ratchet session;
  /// the returned record carries the X3DH state so the caller can build the
  /// initial wire prefix without relying on shared instance fields (#655).
  Future<({SignalSession session, X3dhInitResult? x3dhResult, int? otpKeyId})>
  getOrCreateSession(String peerUserId) async {
    final cached = _sessions.get(peerUserId);
    if (cached != null) {
      return (session: cached, x3dhResult: null, otpKeyId: null);
    }

    // Cache miss may be due to TTL/LRU eviction -- attempt non-destructive
    // reload from secure storage before falling back to a fresh X3DH.
    final reloaded = await _reloadSession(peerUserId);
    if (reloaded != null) {
      return (session: reloaded, x3dhResult: null, otpKeyId: null);
    }

    if (_identityKeyPair == null) await init();

    // Fetch peer's PreKey bundle from server (retry once on 401)
    var response = await http.get(
      Uri.parse('$serverUrl/api/keys/bundle/$peerUserId'),
      headers: {'Authorization': 'Bearer $_token'},
    );

    if (response.statusCode == 401) {
      // Token may be stale — caller should refresh and retry
      throw Exception('Auth expired fetching keys for $peerUserId');
    }
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

    // Block silent session establishment when the peer's identity key has
    // changed since first contact. The user must explicitly accept the new
    // key (via [acceptIdentityKeyChange]) after verifying the safety number;
    // otherwise we would happily X3DH against an attacker-supplied key.
    // (#580)
    final newIdentityKeyB64 = data['identity_key'] as String;
    final tofuStore = SecureKeyStore.instance;
    final existingIdentityKeyB64 = await tofuStore.read(
      '$_peerIdentityPrefix$peerUserId',
    );
    if (existingIdentityKeyB64 != null &&
        existingIdentityKeyB64 != newIdentityKeyB64) {
      // Mark the change so the UI can show a banner even if the caller
      // catches the exception silently.
      await tofuStore.write(
        '$_peerIdentityChangedPrefix$peerUserId',
        DateTime.now().toIso8601String(),
      );
      throw IdentityKeyChangedException(
        peerUserId: peerUserId,
        oldIdentityKeyB64: existingIdentityKeyB64,
        newIdentityKeyB64: newIdentityKeyB64,
      );
    }

    // Cache peer identity key with TOFU change detection
    await _storePeerIdentityKeyTofu(peerUserId, newIdentityKeyB64);

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

    // Initialize Double Ratchet as Alice.
    // Bob's signed prekey serves as his initial ratchet public key.
    final session = await SignalSession.initAlice(
      x3dhResult.sharedSecret,
      bobSignedPrekey,
    );

    _sessions.put(peerUserId, session);
    await _saveSession(peerUserId, session);

    // Return the X3DH state alongside the session so the caller can build the
    // initial-message header. otpKeyId is the prekey id consumed (if any).
    return (session: session, x3dhResult: x3dhResult, otpKeyId: otpKeyId);
  }

  // Magic byte prefix for initial messages that include X3DH key exchange data.
  // V1: [0xEC, 0x01] || identity(32) || ephemeral(32) || session_wire (no OTP)
  // V2: [0xEC, 0x02] || identity(32) || ephemeral(32) || otp_key_id(4 LE) || session_wire (with OTP)
  static const _initialMsgMagicV1 = [0xEC, 0x01];
  static const _initialMsgMagicV2 = [0xEC, 0x02];

  /// Build the initial message wire format with X3DH key exchange header.
  ///
  /// If [x3dhResult] is null, returns [sessionWire] unchanged (normal message).
  /// Otherwise prepends V2 (with [otpKeyId]) or V1 (no OTP) header. The X3DH
  /// state is passed in as locals (not read from instance fields) so concurrent
  /// calls to different peers cannot clobber each other's initial-message
  /// state (#655).
  Future<Uint8List> _buildInitialWire(
    Uint8List sessionWire, {
    required X3dhInitResult? x3dhResult,
    required int? otpKeyId,
  }) async {
    if (x3dhResult == null) return sessionWire;

    final idPub = (await _identityKeyPair!.extractPublicKey()).bytes;
    final ephPub = x3dhResult.ephemeralPublic.bytes;

    Uint8List wire;
    if (otpKeyId != null) {
      wire = Uint8List(2 + 32 + 32 + 4 + sessionWire.length);
      wire[0] = _initialMsgMagicV2[0];
      wire[1] = _initialMsgMagicV2[1];
      wire.setRange(2, 34, Uint8List.fromList(idPub));
      wire.setRange(34, 66, Uint8List.fromList(ephPub));
      final bd = ByteData.sublistView(wire);
      bd.setInt32(66, otpKeyId, Endian.little);
      wire.setRange(70, wire.length, sessionWire);
    } else {
      wire = Uint8List(2 + 32 + 32 + sessionWire.length);
      wire[0] = _initialMsgMagicV1[0];
      wire[1] = _initialMsgMagicV1[1];
      wire.setRange(2, 34, Uint8List.fromList(idPub));
      wire.setRange(34, 66, Uint8List.fromList(ephPub));
      wire.setRange(66, wire.length, sessionWire);
    }

    return wire;
  }

  /// Encrypt a plaintext message for a specific peer.
  ///
  /// For the first message (new session), includes X3DH key exchange data
  /// so the receiver can establish the session as Bob.
  Future<String> encryptMessage(String peerUserId, String plaintext) =>
      _withSessionLock(
        peerUserId,
        () => _encryptMessageImpl(peerUserId, plaintext),
      );

  Future<String> _encryptMessageImpl(
    String peerUserId,
    String plaintext,
  ) async {
    var sessionInfo = await getOrCreateSession(peerUserId);
    var session = sessionInfo.session;
    // "New" means X3DH just ran (initial message will need the X3DH prefix).
    // A session reloaded from secure storage after cache eviction is NOT new.
    var x3dhResult = sessionInfo.x3dhResult;
    var otpKeyId = sessionInfo.otpKeyId;
    var isNewSession = x3dhResult != null;
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));

    Uint8List wire;
    try {
      // Write-ahead: save session state BEFORE mutation so that if the app
      // crashes between encrypt and the post-save, the session reloads to the
      // pre-mutation state.  The unsent message can safely be re-encrypted.
      if (!isNewSession) {
        await _saveSession(peerUserId, session);
      }
      wire = await session.encrypt(plaintextBytes);
    } catch (e) {
      // Session corrupted/stale — clear and retry once with fresh X3DH
      debugPrint(
        '[Crypto] Encrypt failed for $peerUserId, resetting session: $e',
      );
      _sessions.remove(peerUserId);
      await SecureKeyStore.instance.delete('$_sessionPrefix$peerUserId');
      sessionInfo = await getOrCreateSession(peerUserId);
      session = sessionInfo.session;
      x3dhResult = sessionInfo.x3dhResult;
      otpKeyId = sessionInfo.otpKeyId;
      isNewSession = true;
      wire = await session.encrypt(plaintextBytes);
    }

    final finalWire = await _buildInitialWire(
      wire,
      x3dhResult: x3dhResult,
      otpKeyId: otpKeyId,
    );

    await _saveSession(peerUserId, session);
    // Refresh LRU ordering after in-place mutation.
    _sessions.put(peerUserId, session);
    return base64Encode(finalWire);
  }

  /// Decrypt a base64-encoded ciphertext from a specific peer.
  ///
  /// If this is an initial message (contains X3DH key exchange prefix),
  /// establishes the session as Bob (responder) before decrypting.
  ///
  /// [fromDeviceId] is the sender's device ID (from `from_device_id` in the
  /// server message). When provided, sessions are keyed per-device.
  Future<String> decryptMessage(
    String peerUserId,
    String ciphertextB64, {
    int? fromDeviceId,
  }) {
    final sessionKey = _sessionKeyFor(peerUserId, fromDeviceId);
    return _withSessionLock(
      sessionKey,
      () => _decryptMessageImpl(peerUserId, ciphertextB64, fromDeviceId),
    );
  }

  /// Resolve the session map key: prefer `userId:deviceId` when device is
  /// known, fall back to `userId` for legacy sessions.
  String _sessionKeyFor(String peerUserId, int? deviceId) {
    if (deviceId != null) {
      final key = '$peerUserId:$deviceId';
      if (_sessions.isFresh(key)) return key;
      // Fall back to legacy key if device-specific doesn't exist yet
      if (_sessions.isFresh(peerUserId)) return peerUserId;
      return key; // Will create with device-specific key
    }
    return peerUserId;
  }

  Future<String> _decryptMessageImpl(
    String peerUserId,
    String ciphertextB64,
    int? fromDeviceId,
  ) async {
    final sessionKey = _sessionKeyFor(peerUserId, fromDeviceId);
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
    if (isV1 || isV2) {
      return _decryptInitialMessage(
        fullWire: fullWire,
        isV2: isV2,
        sessionKey: sessionKey,
        peerUserId: peerUserId,
        fromDeviceId: fromDeviceId,
      );
    }

    return _decryptNormalMessage(fullWire: fullWire, sessionKey: sessionKey);
  }

  /// Decrypt an initial X3DH message and establish a new session as Bob.
  Future<String> _decryptInitialMessage({
    required Uint8List fullWire,
    required bool isV2,
    required String sessionKey,
    required String peerUserId,
    required int? fromDeviceId,
  }) async {
    await _clearStaleSession(sessionKey, peerUserId, fromDeviceId);

    final aliceIdentityBytes = fullWire.sublist(2, 34);
    final aliceIdentityPub = SimplePublicKey(
      aliceIdentityBytes,
      type: KeyPairType.x25519,
    );
    final aliceEphemeralPub = SimplePublicKey(
      fullWire.sublist(34, 66),
      type: KeyPairType.x25519,
    );

    final (:bobOtp, :sessionWire) = await _parseOtpAndSessionWire(
      fullWire,
      isV2,
    );

    // Cache peer identity key with TOFU change detection
    await _storePeerIdentityKeyTofu(
      peerUserId,
      base64Encode(aliceIdentityBytes),
    );

    if (_signedPrekeyPair == null) await init();

    final (:sharedSecret, :prekeyToUse) = await _computeX3dhResponse(
      bobOtp: bobOtp,
      aliceIdentityPub: aliceIdentityPub,
      aliceEphemeralPub: aliceEphemeralPub,
    );

    final session = await SignalSession.initBob(sharedSecret, prekeyToUse);
    final List<int> plainBytes;
    try {
      plainBytes = await session.decrypt(sessionWire);
    } catch (e) {
      // Initial X3DH wire failed AES-GCM auth -- almost always because our
      // server-side bundle was stale and the sender encrypted against a
      // signed prekey / OTP whose private half we no longer hold (#662).
      // Re-upload our keys (fire-and-forget) so the NEXT message from this
      // peer authenticates, and surface the failure as a typed exception so
      // UI can show "couldn't establish secure session".
      debugPrint(
        '[Crypto] Initial X3DH decrypt failed for $peerUserId: $e -- '
        'scheduling key re-upload to heal stale bundle',
      );
      _needsOtpReplenishment = true;
      unawaited(
        uploadKeys().catchError((upErr) {
          debugPrint('[Crypto] heal uploadKeys failed: $upErr');
        }),
      );
      throw InitialDecryptFailedException(peerUserId);
    }
    _sessions.put(sessionKey, session);
    await _saveSession(sessionKey, session);

    // Consume the OTP -- delete after successful use (one-time)
    if (bobOtp != null && isV2) {
      final bd2 = ByteData.sublistView(fullWire);
      final consumedId = bd2.getInt32(66, Endian.little);
      await _deleteOtpPrivateKey(consumedId);
    }

    unawaited(checkAndReplenishOtpKeys());
    return utf8.decode(plainBytes);
  }

  /// Drop stale sessions so a fresh X3DH session can be established.
  Future<void> _clearStaleSession(
    String sessionKey,
    String peerUserId,
    int? fromDeviceId,
  ) async {
    // containsKey (not isFresh) intentional: drop any in-map entry, expired or not.
    if (_sessions.containsKey(sessionKey)) {
      debugPrint(
        '[Crypto] Replacing stale session for $sessionKey '
        '(received new X3DH initial message)',
      );
      _sessions.remove(sessionKey);
      final store = SecureKeyStore.instance;
      await store.delete('$_sessionPrefix$sessionKey');
    }
    // containsKey (not isFresh) intentional: drop any in-map entry, expired or not.
    if (fromDeviceId != null && _sessions.containsKey(peerUserId)) {
      _sessions.remove(peerUserId);
      final store = SecureKeyStore.instance;
      await store.delete('$_sessionPrefix$peerUserId');
    }
  }

  /// Parse the OTP key pair and session wire bytes from the initial message.
  Future<({SimpleKeyPair? bobOtp, Uint8List sessionWire})>
  _parseOtpAndSessionWire(Uint8List fullWire, bool isV2) async {
    if (!isV2) {
      return (bobOtp: null, sessionWire: fullWire.sublist(66));
    }

    final bd = ByteData.sublistView(fullWire);
    final otpKeyId = bd.getInt32(66, Endian.little);
    final sessionWire = fullWire.sublist(70);
    final bobOtp = await _loadOtpPrivateKey(otpKeyId);
    if (bobOtp != null) {
      debugPrint('[Crypto] Using OTP key_id=$otpKeyId for 4-DH');
    } else {
      throw Exception(
        'OTP key_id=$otpKeyId not found. '
        'Ask the sender to resend the message.',
      );
    }
    return (bobOtp: bobOtp, sessionWire: sessionWire);
  }

  /// Compute the X3DH shared secret as Bob, trying current prekey first,
  /// then falling back to the previous signed prekey.
  Future<({Uint8List sharedSecret, SimpleKeyPair prekeyToUse})>
  _computeX3dhResponse({
    required SimpleKeyPair? bobOtp,
    required SimplePublicKey aliceIdentityPub,
    required SimplePublicKey aliceEphemeralPub,
  }) async {
    try {
      final sharedSecret = await X3DH.respond(
        bobIdentity: _identityKeyPair!,
        bobSignedPrekey: _signedPrekeyPair!,
        bobOneTimePrekey: bobOtp,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: aliceEphemeralPub,
      );
      return (sharedSecret: sharedSecret, prekeyToUse: _signedPrekeyPair!);
    } catch (_) {
      final prevPrekey = await _loadPreviousSignedPrekey();
      if (prevPrekey == null) rethrow;
      final sharedSecret = await X3DH.respond(
        bobIdentity: _identityKeyPair!,
        bobSignedPrekey: prevPrekey,
        bobOneTimePrekey: bobOtp,
        aliceIdentityKey: aliceIdentityPub,
        aliceEphemeralKey: aliceEphemeralPub,
      );
      return (sharedSecret: sharedSecret, prekeyToUse: prevPrekey);
    }
  }

  /// Decrypt a normal (non-initial) message using an existing session.
  ///
  /// The pure Double Ratchet crypto runs in a Flutter [compute] isolate so the
  /// UI thread is never blocked.  Session state is serialised to a plain Map
  /// before entering the isolate and the updated state is deserialised and
  /// applied back on the main thread after [_decryptNormalInIsolate] returns.
  Future<String> _decryptNormalMessage({
    required Uint8List fullWire,
    required String sessionKey,
  }) async {
    // Cache miss may be a TTL/LRU eviction -- try to reload from disk first.
    var session = _sessions.get(sessionKey);
    session ??= await _reloadSession(sessionKey);
    if (session == null) {
      throw Exception(
        'No session for $sessionKey — cannot decrypt normal message. '
        'Awaiting new X3DH initial message from peer.',
      );
    }
    // Serialise session state before any mutation (write-ahead for crash
    // recovery) and before passing into the isolate.
    final sessionJsonBefore = await session.toJson();
    await _saveSession(sessionKey, session);
    try {
      // Run pure Double Ratchet crypto off the UI thread.  The isolate
      // receives a snapshot of the session state and the wire bytes; it
      // returns the decrypted plaintext bytes and the mutated session state.
      // No Hive boxes, SecureKeyStore handles, or singletons are touched
      // inside the isolate -- it is a pure input → output computation.
      final result = await compute(_decryptNormalInIsolate, {
        'session': sessionJsonBefore,
        'wire': fullWire,
      });
      // Apply the updated ratchet state returned from the isolate.
      final updatedSession = SignalSession.fromJson(
        result['session'] as Map<String, dynamic>,
      );
      await _saveSession(sessionKey, updatedSession);
      // Refresh LRU ordering after state update.
      _sessions.put(sessionKey, updatedSession);
      return utf8.decode(result['plaintext'] as Uint8List);
    } catch (e) {
      // Session is stale/corrupted — clear it. The next incoming initial
      // message from this peer will establish a fresh session via X3DH.
      // We do NOT create a new outgoing session here (that would break sync).
      debugPrint(
        '[Crypto] Normal decrypt failed for $sessionKey, '
        'clearing stale session: $e',
      );
      _sessions.remove(sessionKey);
      await SecureKeyStore.instance.delete('$_sessionPrefix$sessionKey');
      rethrow;
    }
  }

  /// Attempt to decrypt a historical message using the existing session.
  ///
  /// Unlike [decryptMessage], this method:
  /// - Never creates a new X3DH session (avoids polluting state)
  /// - Returns null on failure instead of throwing
  /// - Is safe to call for messages the session may have already advanced past
  ///
  /// The Double Ratchet consumes per-message keys once; re-decryption is only
  /// possible for messages whose keys are still in the skipped-keys window.
  /// Callers should check the Hive cache first before calling this method.
  Future<String?> decryptHistoryMessage(
    String peerUserId,
    String ciphertextB64, {
    int? fromDeviceId,
  }) async {
    try {
      final fullWire = Uint8List.fromList(base64Decode(ciphertextB64));

      // Initial messages (X3DH prefix) in history should not re-establish
      // sessions — that would break the current session state.
      final isV1 =
          fullWire.length > 66 &&
          fullWire[0] == _initialMsgMagicV1[0] &&
          fullWire[1] == _initialMsgMagicV1[1];
      final isV2 =
          fullWire.length > 70 &&
          fullWire[0] == _initialMsgMagicV2[0] &&
          fullWire[1] == _initialMsgMagicV2[1];
      if (isV1 || isV2) {
        // Can't safely re-process X3DH from history
        return null;
      }

      // #557: when the originating device is known, prefer the per-device
      // session (`peerUserId:fromDeviceId`) so multi-device DM history is
      // decrypted on the right ratchet. Falls through to the legacy
      // peer-only key when there's no device-specific session yet.
      // Track the actual key the session was loaded from so we save the
      // advanced ratchet state back to the same slot it came from -- using
      // `_sessions.containsKey(...)` after the fact would mis-route under
      // LRU TTL expiry and write a foreign session over a fresh slot.
      final preferredKey = _sessionKeyFor(peerUserId, fromDeviceId);
      var loadedKey = preferredKey;
      var session = _sessions.get(preferredKey);
      session ??= await _reloadSession(preferredKey);
      if (session == null && preferredKey != peerUserId) {
        loadedKey = peerUserId;
        session = _sessions.get(peerUserId);
        session ??= await _reloadSession(peerUserId);
      }
      if (session == null) return null;

      final plainBytes = await session.decrypt(fullWire);
      await _saveSession(loadedKey, session);
      // Refresh LRU ordering after in-place mutation.
      _sessions.put(loadedKey, session);
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }

  /// Check whether a session can be established with [peerUserId].
  ///
  /// Returns true immediately if a session already exists. Otherwise queries
  /// the server for the peer's key bundle and returns true when one is
  /// available.
  Future<bool> canEstablishSession(String peerUserId) async {
    if (_sessions.isFresh(peerUserId)) return true;
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
    return _sessions.isFresh(peerUserId);
  }

  /// Invalidate the cached session for a peer so the next call to
  /// [getOrCreateSession] will re-fetch from the server and create a new session.
  Future<void> invalidateSessionKey(String peerUserId) async {
    _sessions.remove(peerUserId);
    _corruptedSessions.remove(peerUserId);
    final store = SecureKeyStore.instance;
    await store.delete('$_sessionPrefix$peerUserId');
    await store.delete('${_sessionPrefix}corrupt_$peerUserId');
    // Also clear the cached peer identity key and any TOFU change flag so
    // it's re-fetched with the new bundle on next session establishment.
    await store.delete('$_peerIdentityPrefix$peerUserId');
    await store.delete('$_peerIdentityChangedPrefix$peerUserId');
  }

  /// Reset all keys: clear server fingerprint, delete local keys, regenerate,
  /// and upload a fresh bundle.
  ///
  /// [password] is required for server-side re-authentication to clear the
  /// identity key fingerprint binding.
  Future<void> resetAllKeys(String password) async {
    // Clear the server-side identity fingerprint first so the new key upload
    // won't be rejected with 409.
    final resetResponse = await http.post(
      Uri.parse('$serverUrl/api/keys/reset'),
      headers: {
        _contentTypeHeader: _applicationJson,
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'password': password}),
    );

    if (resetResponse.statusCode != 204) {
      throw Exception(
        'Server key reset failed: HTTP ${resetResponse.statusCode} '
        '${resetResponse.body}',
      );
    }

    final store = SecureKeyStore.instance;
    for (final key in _allCryptoKeys) {
      await store.delete(key);
    }
    // Keep the OTP counter at its current value to avoid key-ID collisions
    // with OTPs that the server may have already distributed to peers.
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith(_sessionPrefix) ||
          key.startsWith(_otpPrivatePrefix) ||
          key.startsWith(_peerIdentityPrefix) ||
          key.startsWith(_peerIdentityChangedPrefix)) {
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

  /// Reset only THIS device's keys without disturbing peer sessions (#664).
  ///
  /// Calls `POST /api/keys/reset_device` to clear the server-side per-device
  /// fingerprint binding, then regenerates the local identity / signing /
  /// signed-prekey pair, bumps the OTP counter, and re-uploads. Peer sessions
  /// (sessions whose key does NOT start with `myUserId`) are intentionally
  /// preserved -- the peer's identity key has not changed, only ours.
  ///
  /// [password] is required for server-side re-auth.
  /// [myUserId] (optional) is the caller's user id; when provided, only the
  /// caller's own self-sessions (`myUserId` and `myUserId:<deviceId>`) and
  /// own bundle cache are cleared.
  Future<void> resetThisDeviceKeys(String password, {String? myUserId}) async {
    final resp = await http.post(
      Uri.parse('$serverUrl/api/keys/reset_device'),
      headers: {
        _contentTypeHeader: _applicationJson,
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'password': password, 'device_id': _deviceId}),
    );
    if (resp.statusCode != 204) {
      throw Exception(
        'Per-device key reset failed: HTTP ${resp.statusCode} ${resp.body}',
      );
    }

    final store = SecureKeyStore.instance;

    // Drop in-memory + persisted self-sessions (`me:<deviceId>`) so the next
    // outbound message to one of our own other devices runs a fresh X3DH
    // against the regenerated keys. Peer sessions are intentionally
    // preserved -- only OUR identity changed, the peer's didn't.
    if (myUserId != null && myUserId.isNotEmpty) {
      final allEntries = await store.readAll();
      for (final k in allEntries.keys) {
        if (k.startsWith('$_sessionPrefix$myUserId:') ||
            k == '$_sessionPrefix$myUserId') {
          await store.delete(k);
        }
      }
      // Also drop in-memory self-sessions (user-id-keyed entries only).
      final toDrop = <String>[];
      _sessions.forEach((k, _) {
        if (k == myUserId || k.startsWith('$myUserId:')) toDrop.add(k);
      });
      for (final k in toDrop) {
        _sessions.remove(k);
      }
      // Drop our own bundle cache so the next encryptForOwnDevices fetches
      // the freshly-uploaded bundle.
      _bundleCache.remove(myUserId);
    }

    // Bump the OTP counter so newly-generated OTPs do not collide with any
    // IDs the server may still have pinned to the old bundle.
    final stored = await store.read(_otpNextIdPref);
    final cur = int.tryParse(stored ?? '0') ?? 0;
    await store.write(_otpNextIdPref, '${cur + 100}');

    // Regenerate identity / signing / signed-prekey IN PLACE (cannot route
    // through init() because init's regen branch purges every session in
    // storage, and we explicitly need to preserve peer sessions here).
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
    _needsOtpReplenishment = true;
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
          key.startsWith(_peerIdentityChangedPrefix) ||
          key.startsWith(_otpPrivatePrefix)) {
        await store.delete(key);
      }
    }
  }

  /// Clear in-memory crypto state without touching secure storage.
  ///
  /// Safe to call on logout when the same user (or any user) will log back in
  /// on this device. Stored keys remain intact so [init()] can reload them on
  /// the next [initAndUploadKeys()] call.  Identity keys must NOT be deleted
  /// on logout because deleting them causes [init()] to regenerate a brand-new
  /// identity, permanently breaking decryption of all prior messages.
  void clearInMemoryState() {
    _identityKeyPair = null;
    _signingKeyPair = null;
    _signedPrekeyPair = null;
    _sessions.clear();
    _keysAreFresh = false;
    _keysWereRegenerated = false;
    _needsOtpReplenishment = false;
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
  // Multi-device encryption
  // -----------------------------------------------------------------------

  /// Fetch all device bundles for a peer, with a 5-minute cache.
  Future<List<Map<String, dynamic>>> _fetchAllBundles(String userId) async {
    final cached = _bundleCache[userId];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < _bundleCacheTtl) {
      return cached.$1;
    }

    final response = await http.get(
      Uri.parse('$serverUrl/api/keys/bundles/$userId'),
      headers: {'Authorization': 'Bearer $_token'},
    );

    if (response.statusCode == 401) {
      throw Exception('Auth expired fetching bundles for $userId');
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch bundles for $userId: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final bundles = (data['bundles'] as List).cast<Map<String, dynamic>>();
    _bundleCache[userId] = (bundles, DateTime.now());
    return bundles;
  }

  /// Get or create a Signal session for a specific device of a peer.
  ///
  /// Uses device-specific session key (`userId:deviceId`). Returns the X3DH
  /// state alongside the session so the caller can build the initial-message
  /// header without relying on shared instance fields (#655). For cached or
  /// reloaded sessions, the X3DH fields are null (no initial header needed).
  Future<({SignalSession session, X3dhInitResult? x3dhResult, int? otpKeyId})>
  _getOrCreateSessionForDevice(
    String peerUserId,
    int deviceId,
    Map<String, dynamic> bundleData,
  ) async {
    final sessionKey = '$peerUserId:$deviceId';
    final cached = _sessions.get(sessionKey);
    if (cached != null) {
      return (session: cached, x3dhResult: null, otpKeyId: null);
    }

    // Cache miss may be due to TTL/LRU eviction -- try non-destructive reload.
    final reloaded = await _reloadSession(sessionKey);
    if (reloaded != null) {
      return (session: reloaded, x3dhResult: null, otpKeyId: null);
    }

    // Fall back to legacy session if it exists (pre-multi-device)
    final legacy = _sessions.get(peerUserId);
    if (legacy != null) {
      return (session: legacy, x3dhResult: null, otpKeyId: null);
    }
    final legacyReloaded = await _reloadSession(peerUserId);
    if (legacyReloaded != null) {
      return (session: legacyReloaded, x3dhResult: null, otpKeyId: null);
    }

    if (_identityKeyPair == null) await init();

    final identityKeyB64 = bundleData['identity_key'] as String;
    final bobIdentityKeyBytes = base64Decode(identityKeyB64);
    final bobSignedPrekeyBytes = base64Decode(
      bundleData['signed_prekey'] as String,
    );

    // TOFU check for this device's identity key
    await _storePeerIdentityKeyTofu(peerUserId, identityKeyB64);

    // Verify signed prekey signature
    final signingKeyB64 = bundleData['signing_key'] as String?;
    final signatureB64 = bundleData['signed_prekey_signature'] as String?;
    if (signingKeyB64 != null && signatureB64 != null) {
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
          'device $deviceId -- possible MITM attack',
        );
      }
    }

    final bobIdentityKey = SimplePublicKey(
      bobIdentityKeyBytes,
      type: KeyPairType.x25519,
    );
    final bobSignedPrekey = SimplePublicKey(
      bobSignedPrekeyBytes,
      type: KeyPairType.x25519,
    );

    // Extract one-time prekey if available
    SimplePublicKey? bobOneTimePrekey;
    int? otpKeyId;
    final otpData = bundleData['one_time_prekey'] as Map<String, dynamic>?;
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

    final x3dhResult = await X3DH.initiate(
      aliceIdentity: _identityKeyPair!,
      bobIdentityKey: bobIdentityKey,
      bobSignedPrekey: bobSignedPrekey,
      bobOneTimePrekey: bobOneTimePrekey,
    );

    final session = await SignalSession.initAlice(
      x3dhResult.sharedSecret,
      bobSignedPrekey,
    );

    _sessions.put(sessionKey, session);
    await _saveSession(sessionKey, session);
    return (session: session, x3dhResult: x3dhResult, otpKeyId: otpKeyId);
  }

  /// Encrypt a message for ALL devices of a peer.
  ///
  /// Returns a map of `{deviceId: base64Ciphertext}` for each device.
  /// This enables multi-device delivery where each device gets its own
  /// ciphertext encrypted with a device-specific session.
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) async {
    // First-send heal (#662): if we don't currently have ANY session for this
    // peer (cache miss across all devices) but we DO hold a cached bundle
    // from a prior fetch, evict the cached bundle so the upcoming
    // _fetchAllBundles re-pulls fresh keys. Stale cached bundles are the root
    // cause of the "first DM can't decrypt until peer replies" bug.
    if (_bundleCache.containsKey(peerUserId) &&
        !_hasAnySessionForPeer(peerUserId)) {
      invalidateBundleCache(peerUserId);
    }
    final bundles = await _fetchAllBundles(peerUserId);
    if (bundles.isEmpty) {
      // Fall back to legacy single-device encrypt
      final ct = await encryptMessage(peerUserId, plaintext);
      return {'0': ct};
    }

    final results = <String, String>{};
    for (final bundle in bundles) {
      final deviceId = bundle['device_id'] as int;
      try {
        final sessionKey = '$peerUserId:$deviceId';
        final ct = await _withSessionLock(sessionKey, () async {
          final info = await _getOrCreateSessionForDevice(
            peerUserId,
            deviceId,
            bundle,
          );
          final session = info.session;
          final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));

          // For an existing (cached or reloaded) session, write-ahead save
          // before the ratchet mutation so a crash mid-encrypt is recoverable.
          // For a brand-new X3DH session there is no previous state to save.
          if (info.x3dhResult == null) {
            await _saveSession(sessionKey, session);
          }

          final wire = await session.encrypt(plaintextBytes);
          final finalWire = await _buildInitialWire(
            wire,
            x3dhResult: info.x3dhResult,
            otpKeyId: info.otpKeyId,
          );

          await _saveSession(sessionKey, session);
          // Refresh LRU ordering after in-place mutation.
          _sessions.put(sessionKey, session);
          return base64Encode(finalWire);
        });
        results[deviceId.toString()] = ct;
      } catch (e) {
        debugPrint(
          '[Crypto] Failed to encrypt for $peerUserId device $deviceId: $e',
        );
      }
    }
    return results;
  }

  /// Encrypt for the sender's own other devices given the sender's user ID.
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) async {
    try {
      // Same first-send bundle-cache heal as `encryptForAllDevices` (#662).
      if (_bundleCache.containsKey(myUserId) &&
          !_hasAnySessionForPeer(myUserId)) {
        invalidateBundleCache(myUserId);
      }
      final bundles = await _fetchAllBundles(myUserId);
      final results = <String, String>{};
      for (final bundle in bundles) {
        final deviceId = bundle['device_id'] as int;
        if (deviceId == _deviceId) continue; // Skip current device
        try {
          final sessionKey = '$myUserId:$deviceId';
          final ct = await _withSessionLock(sessionKey, () async {
            final info = await _getOrCreateSessionForDevice(
              myUserId,
              deviceId,
              bundle,
            );
            final session = info.session;
            final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
            if (info.x3dhResult == null) {
              await _saveSession(sessionKey, session);
            }
            final wire = await session.encrypt(plaintextBytes);
            final finalWire = await _buildInitialWire(
              wire,
              x3dhResult: info.x3dhResult,
              otpKeyId: info.otpKeyId,
            );

            await _saveSession(sessionKey, session);
            // Refresh LRU ordering after in-place mutation.
            _sessions.put(sessionKey, session);
            return base64Encode(finalWire);
          });
          results[deviceId.toString()] = ct;
        } catch (e) {
          debugPrint(
            '[Crypto] Failed to encrypt for self device $deviceId: $e',
          );
        }
      }
      return results;
    } catch (e) {
      debugPrint('[Crypto] Self-device encryption failed: $e');
      return {};
    }
  }

  /// Invalidate the device bundle cache for a specific user.
  void invalidateBundleCache(String userId) {
    _bundleCache.remove(userId);
  }

  /// Visible for testing: seed the bundle cache so the first-send heal path
  /// can be exercised without a real server round-trip (#662).
  @visibleForTesting
  void debugSeedBundleCache(String userId, List<Map<String, dynamic>> bundles) {
    _bundleCache[userId] = (bundles, DateTime.now());
  }

  /// Visible for testing: probe whether the bundle cache currently holds an
  /// entry for [userId]. Used by the first-send-heal regression test.
  @visibleForTesting
  bool debugBundleCacheContains(String userId) =>
      _bundleCache.containsKey(userId);

  /// True if the in-memory session cache holds at least one fresh entry for
  /// [peerUserId] (legacy `peer` key OR multi-device `peer:<deviceId>` keys).
  /// Used to drive the first-send bundle-cache heal (#662): if we have a
  /// cached bundle but no session for the peer, the cached bundle is almost
  /// certainly stale -- drop it before fetching.
  bool _hasAnySessionForPeer(String peerUserId) {
    if (_sessions.isFresh(peerUserId)) return true;
    var found = false;
    final prefix = '$peerUserId:';
    _sessions.forEach((k, _) {
      if (!found && k.startsWith(prefix)) found = true;
    });
    return found;
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

// ---------------------------------------------------------------------------
// Isolate entry-point for normal Double Ratchet decryption
// ---------------------------------------------------------------------------

/// Top-level function required by [compute] — must not capture any non-sendable
/// state.  Receives a plain [Map] with two entries:
///   - `'session'` → `Map<String, dynamic>` from [SignalSession.toJson]
///   - `'wire'`    → [Uint8List] ciphertext wire bytes
///
/// Returns a [Map] with:
///   - `'plaintext'` → [Uint8List] decoded plaintext bytes
///   - `'session'`   → `Map<String, dynamic>` updated ratchet state from
///                      [SignalSession.toJson] after decryption
///
/// All crypto is pure Dart (the `cryptography` package).  No Hive boxes,
/// SecureKeyStore, or platform channels are touched — this is safe to run on a
/// background isolate.
Future<Map<String, dynamic>> _decryptNormalInIsolate(
  Map<String, dynamic> payload,
) async {
  final sessionJson = payload['session'] as Map<String, dynamic>;
  final wire = payload['wire'] as Uint8List;

  final session = SignalSession.fromJson(sessionJson);
  final plainBytes = await session.decrypt(wire);
  final updatedJson = await session.toJson();

  return {'plaintext': Uint8List.fromList(plainBytes), 'session': updatedJson};
}
