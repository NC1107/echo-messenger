part of '../crypto_service.dart';

/// Init / migration / key-rotation methods extracted from [CryptoService].
///
/// These methods do NOT touch the encrypt/decrypt or wire-format code paths;
/// the cryptographic primitives (X25519/Ed25519 key generation, signed-prekey
/// rotation policy, secure-storage I/O) are unchanged from the original
/// definitions. See `crypto_service.dart` for the encrypt/decrypt logic.
extension CryptoServiceInit on CryptoService {
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
    for (final key in CryptoService._allCryptoKeys) {
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
          key.startsWith(CryptoService._sessionPrefix) ||
          key.startsWith(CryptoService._otpPrivatePrefix) ||
          key.startsWith(CryptoService._peerIdentityPrefix) ||
          key.startsWith(CryptoService._peerIdentityChangedPrefix);
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
    for (final key in [
      CryptoService._deviceIdPref,
      CryptoService._otpNextIdPref,
    ]) {
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
    final publicBytes = base64Decode(
      (await read(CryptoService._identityPubKeyPref))!,
    );
    _identityKeyPair = SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );

    // Restore Ed25519 signing key pair
    final sigPriv = await read(CryptoService._signingKeyPref);
    final sigPub = await read(CryptoService._signingPubKeyPref);
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
    final spkPriv = await read(CryptoService._signedPrekeyPref);
    final spkPub = await read(CryptoService._signedPrekeyPubPref);
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
      final storedDeviceId = await readWithFallback(
        CryptoService._deviceIdPref,
      );
      await _loadOrGenerateDeviceId(store, storedDeviceId);

      final storedPrivate = await readWithFallback(
        CryptoService._identityKeyPref,
      );

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
      await store.write(CryptoService._deviceIdPref, _deviceId.toString());
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

    await store.write(
      CryptoService._identityKeyPref,
      base64Encode(privateBytes),
    );
    await store.write(
      CryptoService._identityPubKeyPref,
      base64Encode(publicKey.bytes),
    );
    await _saveSigningKey(store);
    await _saveSignedPrekey(store);
    await store.write(
      CryptoService._signedPrekeyCreatedAtPref,
      DateTime.now().toIso8601String(),
    );

    _keysAreFresh = true;
    _needsOtpReplenishment = true; // Fresh install needs OTP keys

    // Purge any stale sessions from storage — they reference the old keys.
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith(CryptoService._sessionPrefix)) {
        await store.delete(key);
      }
    }
  }

  /// Rotate the signed prekey if it is older than [_signedPrekeyMaxAge].
  ///
  /// The old key pair is kept as a "previous" signed prekey for a grace period
  /// so that peers who fetched the old bundle can still complete X3DH.
  Future<void> _rotateSignedPrekeyIfNeeded(SecureKeyStore store) async {
    final createdAtStr = await store.read(
      CryptoService._signedPrekeyCreatedAtPref,
    );
    if (createdAtStr == null) {
      // No timestamp -- store current time and skip rotation this cycle.
      await store.write(
        CryptoService._signedPrekeyCreatedAtPref,
        DateTime.now().toIso8601String(),
      );
      return;
    }

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return;

    final age = DateTime.now().difference(createdAt);
    if (age < CryptoService._signedPrekeyMaxAge) return;

    debugPrint('[Crypto] Signed prekey is ${age.inDays} days old -- rotating');

    // Move current signed prekey to "previous" slot
    final currentPriv = await store.read(CryptoService._signedPrekeyPref);
    final currentPub = await store.read(CryptoService._signedPrekeyPubPref);
    if (currentPriv != null && currentPub != null) {
      await store.write(CryptoService._signedPrekeyPreviousPref, currentPriv);
      await store.write(CryptoService._signedPrekeyPreviousPubPref, currentPub);
    }

    // Generate new signed prekey
    _signedPrekeyPair = await _x25519.newKeyPair();
    await _saveSignedPrekey(store);
    await store.write(
      CryptoService._signedPrekeyCreatedAtPref,
      DateTime.now().toIso8601String(),
    );

    _keysAreFresh = true;

    // Clean up previous prekey if it has exceeded the grace period
    await _cleanupPreviousPrekey(store);
  }

  /// Remove the previous signed prekey if it is older than the grace period.
  Future<void> _cleanupPreviousPrekey(SecureKeyStore store) async {
    final prevPriv = await store.read(CryptoService._signedPrekeyPreviousPref);
    if (prevPriv == null) return;

    // The previous prekey was created when the current one replaced it.
    // We use the current prekey creation time minus max age as an estimate
    // for when the previous key was active. For simplicity, keep it for
    // one full grace period from now -- it will be cleaned up on the next
    // rotation cycle after that.
    final createdAtStr = await store.read(
      CryptoService._signedPrekeyCreatedAtPref,
    );
    if (createdAtStr == null) return;

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return;

    // If the current prekey is already older than the grace period minus
    // the max age, the previous one has definitely expired.
    final currentAge = DateTime.now().difference(createdAt);
    if (currentAge >= CryptoService._signedPrekeyGracePeriod) {
      await store.delete(CryptoService._signedPrekeyPreviousPref);
      await store.delete(CryptoService._signedPrekeyPreviousPubPref);
      debugPrint('[Crypto] Cleaned up expired previous signed prekey');
    }
  }
}
