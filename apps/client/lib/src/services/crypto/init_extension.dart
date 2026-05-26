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

    // Web: keep prefs copy — SecureKeyStore decrypt can fail post-refresh.
    const removeFromPrefs = !kIsWeb;

    final namedOk = await _migrateNamedKeys(prefs, store, removeFromPrefs);
    final prefixedOk = await _migratePrefixedKeys(
      prefs,
      store,
      removeFromPrefs,
    );
    final counterOk = await _migrateCounterKeys(prefs, store, removeFromPrefs);

    if (namedOk && prefixedOk && counterOk) {
      await store.write('_crypto_migration_complete', 'true');
      debugPrint('[Crypto] Migration complete -- all keys in secure storage');
    } else {
      debugPrint('[Crypto] Migration incomplete -- will retry on next launch');
    }
  }

  /// Migrate named crypto keys (identity, signing, signed prekey) from
  /// [prefs] to [store]. Returns `true` if all present keys migrated without
  /// error.
  Future<bool> _migrateNamedKeys(
    SharedPreferences prefs,
    SecureKeyStore store,
    bool removeFromPrefs,
  ) async {
    var allSucceeded = true;
    for (final key in CryptoService._allCryptoKeys) {
      final value = prefs.getString(key);
      if (value != null) {
        final ok = await _migrateOneKey(
          prefs,
          store,
          key,
          value,
          removeFromPrefs,
        );
        if (!ok) allSucceeded = false;
        if (ok) {
          debugPrint(
            '[Crypto] Migrated $key from SharedPreferences to '
            'secure storage',
          );
        }
      }
    }
    return allSucceeded;
  }

  /// Migrate prefixed crypto keys (sessions, OTP privates, peer identities)
  /// from [prefs] to [store]. Returns `true` if all present keys migrated
  /// without error.
  Future<bool> _migratePrefixedKeys(
    SharedPreferences prefs,
    SecureKeyStore store,
    bool removeFromPrefs,
  ) async {
    var allSucceeded = true;
    for (final key in prefs.getKeys()) {
      final isPrefixed =
          key.startsWith(CryptoService._sessionPrefix) ||
          key.startsWith(CryptoService._otpPrivatePrefix) ||
          key.startsWith(CryptoService._peerIdentityPrefix) ||
          key.startsWith(CryptoService._peerIdentityChangedPrefix);
      if (!isPrefixed) continue;

      final value = prefs.getString(key);
      if (value != null) {
        final ok = await _migrateOneKey(
          prefs,
          store,
          key,
          value,
          removeFromPrefs,
        );
        if (!ok) allSucceeded = false;
        if (ok) debugPrint('[Crypto] Migrated $key to secure storage');
      }
    }
    return allSucceeded;
  }

  /// Migrate counter keys (device ID and OTP next ID) from [prefs] to [store].
  /// Returns `true` if all present keys migrated without error.
  Future<bool> _migrateCounterKeys(
    SharedPreferences prefs,
    SecureKeyStore store,
    bool removeFromPrefs,
  ) async {
    var allSucceeded = true;
    for (final key in [
      CryptoService._deviceIdPref,
      CryptoService._otpNextIdPref,
    ]) {
      final value = prefs.getString(key);
      if (value != null) {
        final ok = await _migrateOneKey(
          prefs,
          store,
          key,
          value,
          removeFromPrefs,
        );
        if (!ok) allSucceeded = false;
      }
    }
    return allSucceeded;
  }

  /// Write a single [key]/[value] pair to [store] and optionally remove from
  /// [prefs]. Returns `true` on success, `false` if the store write threw.
  Future<bool> _migrateOneKey(
    SharedPreferences prefs,
    SecureKeyStore store,
    String key,
    String value,
    bool removeFromPrefs,
  ) async {
    try {
      await store.write(key, value);
      if (removeFromPrefs) await prefs.remove(key);
      return true;
    } catch (e) {
      debugPrint(
        '[Crypto] Migration of $key failed (keeping in SharedPreferences '
        'for next attempt): $e',
      );
      return false;
    }
  }

  /// Restore the X25519 identity key pair from [storedPrivate] and [store].
  Future<void> _restoreIdentityKey(
    SecureKeyStore store,
    String storedPrivate,
    Future<String?> Function(String key) read,
  ) async {
    final privateBytes = base64Decode(storedPrivate);
    final publicBytes = base64Decode(
      (await read(CryptoService._identityPubKeyPref))!,
    );
    _identityKeyPair = SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  /// Restore (or regenerate) the Ed25519 signing key pair from [store].
  Future<void> _restoreSigningKey(
    SecureKeyStore store,
    Future<String?> Function(String key) read,
  ) async {
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
  }

  /// Restore (or regenerate) the X25519 signed prekey pair from [store].
  Future<void> _restoreSignedPrekey(
    SecureKeyStore store,
    Future<String?> Function(String key) read,
  ) async {
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
    Future<String?> read(String key) =>
        readKey != null ? readKey(key) : store.read(key);

    await _restoreIdentityKey(store, storedPrivate, read);
    await _restoreSigningKey(store, read);
    await _restoreSignedPrekey(store, read);

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

      // Web fallback: SecureKeyStore null-reads after WebCrypto key loss
      // (incognito, cleared storage) — prefs is the recovery path.
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
      // Positive random ID (1..2^30) avoids collision with legacy 0.
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
    // Suppress regen warning on true first install (no prior keys existed).
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
  ///
  /// Ordering (audit P2-1 fix): grace-period cleanup runs FIRST, before the
  /// rotation check. Otherwise it would only ever see the *just-rotated*
  /// previous key (whose timestamp was reset moments ago) and the actually-
  /// stale previous from two rotations back would linger indefinitely.
  /// Running cleanup unconditionally also drops stale previous keys on
  /// long-running clients that don't trigger rotation often.
  Future<void> _rotateSignedPrekeyIfNeeded(SecureKeyStore store) async {
    // Audit P2-1: always give the previous-slot a chance to expire,
    // even when no rotation is about to happen.
    await _cleanupPreviousPrekey(store);

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

    // Move current → previous; track real birth so grace-period drop is exact.
    final currentPriv = await store.read(CryptoService._signedPrekeyPref);
    final currentPub = await store.read(CryptoService._signedPrekeyPubPref);
    if (currentPriv != null && currentPub != null) {
      await store.write(CryptoService._signedPrekeyPreviousPref, currentPriv);
      await store.write(CryptoService._signedPrekeyPreviousPubPref, currentPub);
      await store.write(
        CryptoService._signedPrekeyPreviousCreatedAtPref,
        createdAt.toIso8601String(),
      );
    }

    // Generate new signed prekey
    _signedPrekeyPair = await _x25519.newKeyPair();
    await _saveSignedPrekey(store);
    await store.write(
      CryptoService._signedPrekeyCreatedAtPref,
      DateTime.now().toIso8601String(),
    );

    _keysAreFresh = true;
  }

  /// Remove the previous signed prekey if it is older than the grace period.
  /// Compares against the *previous* prekey's recorded createdAt — see
  /// audit P2-1 for why comparing against the current prekey's age was
  /// incorrect (it let the previous key linger up to gracePeriod + maxAge
  /// instead of exactly gracePeriod).
  Future<void> _cleanupPreviousPrekey(SecureKeyStore store) async {
    final prevPriv = await store.read(CryptoService._signedPrekeyPreviousPref);
    if (prevPriv == null) return;

    final prevCreatedAtStr = await store.read(
      CryptoService._signedPrekeyPreviousCreatedAtPref,
    );
    // Pre-fix data lacks timestamp — drop it (peer just re-fetches bundle).
    if (prevCreatedAtStr == null) {
      await store.delete(CryptoService._signedPrekeyPreviousPref);
      await store.delete(CryptoService._signedPrekeyPreviousPubPref);
      debugPrint(
        '[Crypto] Dropping previous signed prekey with no recorded '
        'birth timestamp (pre-P2-1 data)',
      );
      return;
    }

    final prevCreatedAt = DateTime.tryParse(prevCreatedAtStr);
    if (prevCreatedAt == null) return;

    final age = DateTime.now().difference(prevCreatedAt);
    if (age >= CryptoService._signedPrekeyGracePeriod) {
      await store.delete(CryptoService._signedPrekeyPreviousPref);
      await store.delete(CryptoService._signedPrekeyPreviousPubPref);
      await store.delete(CryptoService._signedPrekeyPreviousCreatedAtPref);
      debugPrint(
        '[Crypto] Cleaned up expired previous signed prekey '
        '(was ${age.inDays} days old, grace period '
        '${CryptoService._signedPrekeyGracePeriod.inDays} days)',
      );
    }
  }
}
