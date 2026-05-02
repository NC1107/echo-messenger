// Typed exceptions surfaced by [CryptoService] so callers can branch on
// specific failure modes (TOFU change, identity-key conflict, X3DH initial
// auth failure) instead of parsing English error strings.
//
// Lives in its own library so the (large) `crypto_service.dart` file can be
// split via `part`/`part of` without trapping these public types behind a
// `library;` boundary that other code already imports.

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
