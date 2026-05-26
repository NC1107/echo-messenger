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

import '../utils/crypto_perf.dart';
import 'crypto_exceptions.dart';
import 'debug_log_service.dart';
import 'safety_number_service.dart';
import 'secure_key_store.dart';
import 'session_cache.dart';
import 'signal_session.dart';
import 'signal_x3dh.dart';

// Re-export so existing callers don't need a coordinated import rewrite.
export 'crypto_exceptions.dart';

part 'crypto/init_extension.dart';
part 'crypto/peer_identity_extension.dart';
part 'crypto/otp_extension.dart';

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

  /// TD-29: when TOFU detects a changed peer identity, the *new* key is
  /// stashed here instead of clobbering the canonical
  /// `_peerIdentityPrefix` slot. Callers that need the freshly-fetched key
  /// (e.g. group-key rotation needs to wrap against the server's current
  /// answer, even if not yet trusted) can opt-in via
  /// [pendingPeerIdentityKey]. The canonical slot only moves forward when
  /// [acceptIdentityKeyChange] is called explicitly.
  static const _peerIdentityPendingPrefix = 'echo_peer_identity_pending_';
  static const _otpPrivatePrefix = 'echo_otp_private_';
  static const _signedPrekeyCreatedAtPref = 'echo_signed_prekey_created_at';
  static const _signedPrekeyPreviousPref = 'echo_signed_prekey_previous';
  static const _signedPrekeyPreviousPubPref = 'echo_signed_prekey_previous_pub';

  /// Timestamp at which the *previous* signed prekey was generated.
  /// Used by `_cleanupPreviousPrekey` to drop the previous prekey
  /// exactly `_signedPrekeyGracePeriod` after it was minted, rather
  /// than the audit P2-1 pre-fix behaviour where cleanup compared
  /// against the *current* prekey's age (which let the previous key
  /// linger up to `gracePeriod + maxAge` instead of `gracePeriod`).
  static const _signedPrekeyPreviousCreatedAtPref =
      'echo_signed_prekey_previous_created_at';
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
    _signedPrekeyPreviousCreatedAtPref,
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

  /// Callback invoked when the secure-storage backend is detected to be
  /// unavailable (libsecret locked, Keychain prompt denied, etc.).
  /// `CryptoNotifier` wires this through to its state so the UI can render
  /// a "keyring locked" banner. Audit P0-1.
  void Function()? _onSecureStorageUnavailable;

  /// Callback invoked when the OTP-replenishment / key-upload heal flow has
  /// failed terminally (5 retries with exponential backoff). The provider
  /// flips `keysUploadFailed` based on this so the existing settings banner
  /// becomes visible. Audit P0-2.
  void Function()? _onKeyUploadTerminalFailure;

  /// Install observability callbacks. Called once from the provider on init.
  /// Either argument may be null; nulls clear the corresponding hook.
  void setObservers({
    void Function()? onSecureStorageUnavailable,
    void Function()? onKeyUploadTerminalFailure,
  }) {
    _onSecureStorageUnavailable = onSecureStorageUnavailable;
    _onKeyUploadTerminalFailure = onKeyUploadTerminalFailure;
  }

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

  /// Sender Ed25519 keypair used to sign GRP2 group messages
  /// (audit OQ-12: per-device sender signature). Returns null when
  /// the service hasn't been initialised yet; callers MUST handle
  /// that case by falling back to GRP1 send.
  SimpleKeyPair? get signingKeyPair => _signingKeyPair;

  /// True if identity keys were regenerated (not restored from storage).
  /// This means old encrypted messages cannot be decrypted.
  bool get keysWereRegenerated => _keysWereRegenerated;

  // Init / migration / signed-prekey rotation helpers live in
  // crypto/init_extension.dart (extension CryptoServiceInit).

  // Peer identity / TOFU / safety-number helpers live in
  // crypto/peer_identity_extension.dart (extension CryptoServicePeerIdentity).

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

    // Audit P1-3: log torn-write intents from last shutdown for telemetry.
    // Do NOT auto-discard — next decrypt either succeeds or trips P0-3 banner.
    try {
      final torn = await scanAndClearTornSessionWrites();
      if (torn.isNotEmpty) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'Crypto',
          'Torn session write detected for ${torn.length} session(s): '
              '${torn.join(", ")} — see audit P1-3',
        );
      }
    } catch (e) {
      debugPrint('[Crypto] scanAndClearTornSessionWrites failed: $e');
    }
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

  /// Audit P1-3 torn-write instrumentation marker prefix. Deliberately NOT
  /// `_sessionPrefix` so `_loadSessions` doesn't quarantine the timestamp
  /// value as a corrupted session. See `_beginSessionWriteIntent` /
  /// `scanAndClearTornSessionWrites` for the surrounding flow.
  static const _sessionIntentPrefix = 'echo_session_writeahead_';

  Future<void> _beginSessionWriteIntent(String sessionKey) async {
    try {
      await SecureKeyStore.instance.write(
        '$_sessionIntentPrefix$sessionKey',
        DateTime.now().toIso8601String(),
      );
    } catch (_) {
      // Best-effort. A failed intent-write is itself a torn-write hazard,
      // but since we have nothing better to fall back to, we just proceed —
      // the surrounding session-save will surface the underlying storage
      // problem via the existing typed-exception path.
    }
  }

  Future<void> _endSessionWriteIntent(String sessionKey) async {
    try {
      await SecureKeyStore.instance.delete('$_sessionIntentPrefix$sessionKey');
    } catch (_) {
      // Leaving the marker behind biases the next startup scan toward a
      // false positive, which is the safe failure mode for instrumentation.
    }
  }

  /// Called from [_loadSessions] at startup. Returns the list of session
  /// keys that were mid-write at the last process shutdown. The intent
  /// markers are cleared as a side effect so we don't re-log the same
  /// torn write on every subsequent launch.
  @visibleForTesting
  Future<List<String>> scanAndClearTornSessionWrites() async {
    final store = SecureKeyStore.instance;
    final all = await store.readAll();
    final torn = <String>[];
    for (final entry in all.entries) {
      if (entry.key.startsWith(_sessionIntentPrefix)) {
        torn.add(entry.key.substring(_sessionIntentPrefix.length));
        try {
          await store.delete(entry.key);
        } catch (_) {
          // Failure to clear means we re-surface on next launch — also fine.
        }
      }
    }
    return torn;
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
    } on StorageUnavailableException {
      // Audit P0-1: keyring locked is not "no session" — propagate so caller
      // keeps in-memory session alive and surfaces a banner.
      rethrow;
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
  /// Heal a stale prekey bundle by retrying [uploadKeys] with exponential
  /// backoff. Up to 5 attempts spaced 1s / 2s / 4s / 8s / 16s. On terminal
  /// failure, invokes `_onKeyUploadTerminalFailure` so the provider can flip
  /// `keysUploadFailed` and show the settings banner. Audit P0-2 / #662.
  ///
  /// Visible-for-test override: pass a non-null [delayOverride] to short-
  /// circuit real timer waits.
  @visibleForTesting
  Future<bool> healUploadKeysForTest({
    Future<void> Function(Duration)? delayOverride,
  }) {
    return _healUploadKeysWithBackoff(delayOverride: delayOverride);
  }

  Future<bool> _healUploadKeysWithBackoff({
    Future<void> Function(Duration)? delayOverride,
  }) async {
    const maxAttempts = 5;
    final delay = delayOverride ?? Future<void>.delayed;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await uploadKeys();
        debugPrint('[Crypto] heal uploadKeys succeeded on attempt $attempt');
        return true;
      } catch (e) {
        debugPrint(
          '[Crypto] heal uploadKeys attempt $attempt/$maxAttempts failed: $e',
        );
        if (attempt == maxAttempts) {
          debugPrint('[Crypto] heal uploadKeys exhausted — alerting UI');
          _onKeyUploadTerminalFailure?.call();
          return false;
        }
        // Exponential backoff: 1, 2, 4, 8, 16 seconds.
        await delay(Duration(seconds: 1 << (attempt - 1)));
      }
    }
    return false;
  }

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

    // Only regenerate OTPs on fresh install / regen / low server count;
    // restart-time overwrite would orphan keys the server still hands out.
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
      // (#664) Tolerate both structured `identity_key_conflict` envelope and
      // legacy plain `{"error": "..."}` from older servers.
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

  // OTP generation / replenishment helpers live in
  // crypto/otp_extension.dart (extension CryptoServiceOtp).

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

    // (#580) TOFU: block X3DH against an attacker-substituted key. User must
    // call [acceptIdentityKeyChange] after verifying safety number.
    final newIdentityKeyB64 = data['identity_key'] as String;
    final tofuStore = SecureKeyStore.instance;
    final existingIdentityKeyB64 = await tofuStore.read(
      '$_peerIdentityPrefix$peerUserId',
    );
    if (existingIdentityKeyB64 != null &&
        existingIdentityKeyB64 != newIdentityKeyB64) {
      // Persist change marker so UI shows banner even if caller swallows exception.
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

    // X3DH as Alice (4-DH with OTP if available). P1-4 telemetry isolates
    // one-time X3DH cost from per-message ratchet cost.
    final x3dhResult = await timedCryptoOp(
      'X3DH.initiate',
      () => X3DH.initiate(
        aliceIdentity: _identityKeyPair!,
        bobIdentityKey: bobIdentityKey,
        bobSignedPrekey: bobSignedPrekey,
        bobOneTimePrekey: bobOneTimePrekey,
      ),
      args: {'otp': bobOneTimePrekey != null},
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
        () => timedCryptoOp(
          'CryptoService.encryptMessage',
          () => _encryptMessageImpl(peerUserId, plaintext),
          args: {'peer': peerUserId},
        ),
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
      // Write-ahead: pre-mutation save so a crash mid-encrypt reloads to a
      // state where the unsent message can be re-encrypted safely.
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
      () => timedCryptoOp(
        'CryptoService.decryptMessage',
        () => _decryptMessageImpl(peerUserId, ciphertextB64, fromDeviceId),
        args: {'peer': peerUserId, 'fromDevice': fromDeviceId},
      ),
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
  ) {
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
      // (#662) Initial X3DH AES-GCM fail = stale server bundle; sender used
      // a prekey/OTP whose private half we no longer hold. Re-upload to heal.
      debugPrint(
        '[Crypto] Initial X3DH decrypt failed for $peerUserId: $e -- '
        'scheduling key re-upload to heal stale bundle',
      );
      _needsOtpReplenishment = true;
      unawaited(_healUploadKeysWithBackoff());
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
    try {
      session ??= await _reloadSession(sessionKey);
    } on StorageUnavailableException catch (e) {
      // Keyring locked: don't clear anything (disk session presumed intact);
      // surface typed error so UI shows "keyring locked" banner.
      _onSecureStorageUnavailable?.call();
      throw SessionStorageUnavailableException(sessionKey, e);
    }
    if (session == null) {
      throw Exception(
        'No session for $sessionKey — cannot decrypt normal message. '
        'Awaiting new X3DH initial message from peer.',
      );
    }
    // Serialise session state before any mutation (write-ahead for crash
    // recovery) and before passing into the isolate.
    final sessionJsonBefore = await session.toJson();
    // Audit P1-3: drop a torn-write intent marker so we can detect on
    // next launch that this decrypt was in-flight when the process died.
    await _beginSessionWriteIntent(sessionKey);
    await _saveSession(sessionKey, session);
    try {
      // Pure crypto in isolate (no Hive / SecureKeyStore / singletons).
      final result = await compute(_decryptNormalInIsolate, {
        'session': sessionJsonBefore,
        'wire': fullWire,
      });
      // Apply the updated ratchet state returned from the isolate.
      final updatedSession = SignalSession.fromJson(
        result['session'] as Map<String, dynamic>,
      );
      await _saveSession(sessionKey, updatedSession);
      // Audit P1-3: post-state committed — clear the intent marker.
      await _endSessionWriteIntent(sessionKey);
      // Refresh LRU ordering after state update.
      _sessions.put(sessionKey, updatedSession);
      return utf8.decode(result['plaintext'] as Uint8List);
    } on StorageUnavailableException catch (e) {
      // Post-save storage failure: leave in-memory session alone, surface error.
      // Plaintext already delivered; next decrypt retries or fails identically.
      _onSecureStorageUnavailable?.call();
      throw SessionStorageUnavailableException(sessionKey, e);
    } catch (e) {
      // Clear stale session; do NOT create a new outgoing one (would break sync).
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

      // #557: prefer per-device session; track loaded-from key so we save back
      // to the same slot (containsKey-after-the-fact mis-routes under LRU TTL).
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
    // TD-29: also drop the pending-identity slot so the next fetch starts
    // from a clean TOFU state instead of resurrecting a stale "new" key.
    await store.delete('$_peerIdentityPendingPrefix$peerUserId');
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
          key.startsWith(_peerIdentityChangedPrefix) ||
          key.startsWith(_peerIdentityPendingPrefix)) {
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

    // Drop self-sessions only (peer sessions preserved — only OUR identity changed).
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

    // Regen in place: init()'s regen branch purges peer sessions, which we
    // must preserve here (only OUR identity changed).
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
          key.startsWith(_peerIdentityPendingPrefix) ||
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

  /// Fetch the Ed25519 signing public key for a specific (user, device).
  /// Used by the GRP2 receive path to verify the sender signature
  /// against the device that produced the message (audit OQ-12: per-
  /// device sender signatures). Returns null when no matching device
  /// is found in the bundles list — the caller should surface that
  /// as a verification failure rather than silently accepting.
  ///
  /// The 5-minute bundle TTL applies, so a freshly-rotated device
  /// signing key may take up to that long to propagate. In practice
  /// GRP2 is gated on a successful key rotation, so the bundle
  /// fetched right before the rotation is fresh enough.
  Future<SimplePublicKey?> getSenderVerifyKeyForDevice(
    String userId,
    int? deviceId,
  ) async {
    final bundles = await _fetchAllBundles(userId);
    final filtered = deviceId == null
        ? bundles
        : bundles.where((b) => b['device_id'] == deviceId).toList();
    if (filtered.isEmpty) return null;
    final signingKeyB64 = filtered.first['signing_key'] as String?;
    if (signingKeyB64 == null) return null;
    return SimplePublicKey(
      base64Decode(signingKeyB64),
      type: KeyPairType.ed25519,
    );
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
    // (#662) First-send heal: stale cached bundle without any session = root
    // cause of "first DM undecryptable"; evict so fetch re-pulls fresh keys.
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

          // Write-ahead save before ratchet mutation (recoverable mid-crash).
          // Skip for fresh X3DH session — no previous state to save.
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

  /// TD-28: signed variant of [encryptForUser]. The plaintext wrap is the
  /// same as the unsigned form; we append a 64-byte Ed25519 signature
  /// computed over `eph_pub || nonce || ct || tag` using the rotator's
  /// Ed25519 sender-signing key.
  ///
  /// Wire: base64(ephemeral_pub(32) || nonce(12) || ct || tag(16) || sig(64))
  ///
  /// Recipients verify with [decryptFromUserVerified] against a freshly
  /// fetched signing public key for the claimed rotator. Without this,
  /// nothing in the wire commits to the rotator's identity and a malicious
  /// server / racing admin can publish substitute envelopes.
  Future<String> encryptForUserSigned(
    Uint8List plaintext,
    Uint8List recipientPublicKeyBytes,
  ) async {
    if (_identityKeyPair == null) await init();
    if (_signingKeyPair == null) {
      throw StateError(
        'TD-28: encryptForUserSigned requires a signing key — call init() first',
      );
    }

    // Wrap (same shape as encryptForUser).
    final unsignedB64 = await encryptForUser(
      plaintext,
      recipientPublicKeyBytes,
    );
    final unsignedWire = Uint8List.fromList(base64Decode(unsignedB64));

    // Sign the wire prefix that the recipient will verify.
    final sig = await _ed25519.sign(unsignedWire, keyPair: _signingKeyPair!);
    final sigBytes = Uint8List.fromList(sig.bytes);
    if (sigBytes.length != 64) {
      throw StateError(
        'unexpected Ed25519 signature length: ${sigBytes.length}',
      );
    }

    final signedWire = Uint8List(unsignedWire.length + 64);
    signedWire.setRange(0, unsignedWire.length, unsignedWire);
    signedWire.setRange(unsignedWire.length, signedWire.length, sigBytes);
    return base64Encode(signedWire);
  }

  /// TD-28: verify-then-unwrap counterpart to [encryptForUserSigned].
  ///
  /// Verifies the trailing 64-byte Ed25519 signature against
  /// [senderSigningPublicKey] over the unsigned-prefix bytes, then unwraps
  /// the same way [decryptFromUser] does. Throws when the signature is
  /// missing (legacy unsigned envelope) or invalid.
  ///
  /// Callers that need to accept legacy unsigned envelopes during a
  /// migration window can fall back to [decryptFromUser] only after
  /// confirming a verified signed envelope is genuinely unavailable —
  /// otherwise the audit's substitution attack still applies.
  Future<Uint8List> decryptFromUserVerified(
    String ciphertextB64,
    Uint8List senderSigningPublicKey,
  ) async {
    if (_identityKeyPair == null) await init();

    final wire = Uint8List.fromList(base64Decode(ciphertextB64));
    // Minimum: 32 + 12 + 16 + 64 (sig)
    if (wire.length < 32 + 12 + 16 + 64) {
      throw FormatException(
        'encryptForUserSigned ciphertext too short: ${wire.length} bytes',
      );
    }

    final sigStart = wire.length - 64;
    final unsignedWire = wire.sublist(0, sigStart);
    final sigBytes = wire.sublist(sigStart);

    final signerPub = SimplePublicKey(
      senderSigningPublicKey,
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      unsignedWire,
      signature: Signature(sigBytes, publicKey: signerPub),
    );
    if (!valid) {
      throw const FormatException(
        'TD-28: group-key envelope signature failed verification',
      );
    }

    // Reuse the unsigned-decrypt path on the prefix.
    return decryptFromUser(base64Encode(unsignedWire));
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
