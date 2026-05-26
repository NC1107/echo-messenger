part of '../crypto_service.dart';

/// Peer identity / TOFU / safety-number helpers extracted from
/// [CryptoService]. None of these touch the encrypt/decrypt or wire-format
/// code paths -- they only manage the persisted peer identity-key cache and
/// the "identity key changed" UI flag.
extension CryptoServicePeerIdentity on CryptoService {
  /// Fetch and cache a peer's identity public key from the server.
  ///
  /// Returns the key bytes, or null if unavailable.
  /// Uses Trust-On-First-Use (TOFU): the first-seen key is trusted and
  /// persisted. If a later fetch returns a different key, a warning is logged
  /// and a `_peerIdentityChangedPrefix` flag is persisted for the peer.
  ///
  /// [forceRefresh] bypasses the TOFU cache and always hits the server.
  /// Used by paths that need the *current* server-known key — most notably
  /// group-key rotation, where wrapping the new key against a stale cached
  /// identity would leave the recipient unable to unwrap (MAC failure on
  /// the resulting envelope).
  Future<Uint8List?> fetchPeerIdentityKey(
    String peerUserId, {
    bool forceRefresh = false,
  }) async {
    final store = SecureKeyStore.instance;
    if (!forceRefresh) {
      final cached = await store.read(
        '${CryptoService._peerIdentityPrefix}$peerUserId',
      );
      if (cached != null) return Uint8List.fromList(base64Decode(cached));
    }

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
  /// - First encounter: stores the key in the canonical slot.
  /// - Same key: no-op.
  /// - Different key (TD-29): keep the canonical slot **untouched**, write
  ///   the new key to a separate pending slot, and raise the change flag.
  ///   The DM session-establishment path already throws
  ///   `IdentityKeyChangedException` on the flag, but other consumers
  ///   (group-key rotation, safety-number display) were previously reading
  ///   the freshly-overwritten cache without ever checking the flag — that
  ///   silently trusted the new (possibly MITM) key. Now they must either
  ///   read the canonical slot (default) or explicitly opt-in via
  ///   [pendingPeerIdentityKey].
  Future<void> _storePeerIdentityKeyTofu(
    String peerUserId,
    String newKeyB64,
  ) async {
    final store = SecureKeyStore.instance;
    final canonicalKey = '${CryptoService._peerIdentityPrefix}$peerUserId';
    final existing = await store.read(canonicalKey);

    if (existing == null) {
      // First contact — trust on first use.
      await store.write(canonicalKey, newKeyB64);
      return;
    }

    if (existing == newKeyB64) {
      // Same key, nothing to do. Clear any stale pending entry if one
      // exists (it can be left behind if the peer reverts a key reset).
      await store.delete(
        '${CryptoService._peerIdentityPendingPrefix}$peerUserId',
      );
      return;
    }

    // Key has changed: keep canonical, write pending, raise flag.
    DebugLogService.instance.log(
      LogLevel.warning,
      'Crypto',
      'TOFU: identity key changed for peer $peerUserId -- '
          'possible key reset or MITM. Old prefix: '
          '${existing.substring(0, min(8, existing.length))}..., '
          'new prefix: '
          '${newKeyB64.substring(0, min(8, newKeyB64.length))}... '
          'Canonical cache left intact until acceptIdentityKeyChange().',
    );
    debugPrint('[Crypto] WARNING: peer $peerUserId identity key changed!');
    await store.write(
      '${CryptoService._peerIdentityPendingPrefix}$peerUserId',
      newKeyB64,
    );
    await store.write(
      '${CryptoService._peerIdentityChangedPrefix}$peerUserId',
      DateTime.now().toIso8601String(),
    );
  }

  /// Returns the *pending* identity key the server most recently advertised
  /// for [peerUserId], if the canonical (trusted) key differs. Used by code
  /// paths that legitimately need the new key without overriding TOFU — for
  /// instance, the explicit "accept identity-key change" UI flow, or a
  /// safety-number screen that wants to display the new fingerprint
  /// alongside the trusted one.
  ///
  /// Returns null when there is no pending change.
  Future<Uint8List?> pendingPeerIdentityKey(String peerUserId) async {
    final store = SecureKeyStore.instance;
    final pending = await store.read(
      '${CryptoService._peerIdentityPendingPrefix}$peerUserId',
    );
    if (pending == null) return null;
    return Uint8List.fromList(base64Decode(pending));
  }

  /// Check whether a peer's identity key has changed since first contact.
  Future<bool> hasPeerIdentityKeyChanged(String peerUserId) async {
    final store = SecureKeyStore.instance;
    final flag = await store.read(
      '${CryptoService._peerIdentityChangedPrefix}$peerUserId',
    );
    return flag != null;
  }

  /// Acknowledge a peer identity key change (clears the flag).
  Future<void> acknowledgePeerIdentityKeyChange(String peerUserId) async {
    final store = SecureKeyStore.instance;
    await store.delete(
      '${CryptoService._peerIdentityChangedPrefix}$peerUserId',
    );
  }

  /// Explicitly trust the peer's new identity key after the user has
  /// reviewed (or chosen to skip reviewing) the safety number.
  ///
  /// TD-29: TOFU no longer overwrites the canonical cache silently, so this
  /// path now promotes the pending key (whatever TOFU stashed when the
  /// change was detected) to canonical. Callers can still override by
  /// passing an explicit [newIdentityKeyB64].
  ///
  /// Always clears the change flag and drops the persisted Signal session
  /// keyed to the old identity so the next send re-runs X3DH against the
  /// freshly-trusted key. (#580)
  Future<void> acceptIdentityKeyChange(
    String peerUserId, {
    String? newIdentityKeyB64,
  }) async {
    final store = SecureKeyStore.instance;
    final canonicalKey = '${CryptoService._peerIdentityPrefix}$peerUserId';
    final pendingKey = '${CryptoService._peerIdentityPendingPrefix}$peerUserId';

    final promote = newIdentityKeyB64 ?? await store.read(pendingKey);
    if (promote != null) {
      await store.write(canonicalKey, promote);
    }
    await store.delete(pendingKey);
    await store.delete(
      '${CryptoService._peerIdentityChangedPrefix}$peerUserId',
    );
    // Drop any cached/persisted session keyed to the old identity so the
    // next send re-runs X3DH against the freshly-trusted key.
    _sessions.remove(peerUserId);
    await store.delete('${CryptoService._sessionPrefix}$peerUserId');
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
    final peerB64 = await store.read(
      '${CryptoService._peerIdentityPrefix}$peerUserId',
    );
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
}
