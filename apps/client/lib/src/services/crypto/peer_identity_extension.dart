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
  Future<Uint8List?> fetchPeerIdentityKey(String peerUserId) async {
    // Check cache first
    final store = SecureKeyStore.instance;
    final cached = await store.read(
      '${CryptoService._peerIdentityPrefix}$peerUserId',
    );
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
    final storeKey = '${CryptoService._peerIdentityPrefix}$peerUserId';
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
        '${CryptoService._peerIdentityChangedPrefix}$peerUserId',
        DateTime.now().toIso8601String(),
      );
    }

    // Store the (possibly new) key so future sessions use the latest.
    await store.write(storeKey, newKeyB64);
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
      await store.write(
        '${CryptoService._peerIdentityPrefix}$peerUserId',
        newIdentityKeyB64,
      );
    }
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
