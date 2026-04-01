/// Extended Triple Diffie-Hellman (X3DH) key agreement for Dart.
///
/// Implements the Signal Protocol X3DH specification for asynchronous
/// session establishment. Matches the Rust implementation at
/// `core/rust-core/src/signal/x3dh.rs`.
///
/// Reference: https://signal.org/docs/specifications/x3dh/
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'signal_protocol.dart';

/// Result of an X3DH initiation by Alice.
class X3dhInitResult {
  /// 32-byte shared secret derived from X3DH.
  final Uint8List sharedSecret;

  /// Alice's ephemeral public key -- sent to Bob in the initial message header.
  final SimplePublicKey ephemeralPublic;

  /// Alice's identity public key -- sent to Bob so he can compute the same secret.
  final SimplePublicKey identityPublic;

  X3dhInitResult({
    required this.sharedSecret,
    required this.ephemeralPublic,
    required this.identityPublic,
  });
}

/// X3DH key agreement protocol.
///
/// Provides static methods for both the initiator (Alice) and responder (Bob)
/// sides of the X3DH handshake.
class X3DH {
  static final _x25519 = X25519();

  /// Perform a single X25519 DH operation.
  ///
  /// Returns the 32-byte shared secret from a DH between [keyPair] and [remotePublicKey].
  static Future<Uint8List> _dh(
    SimpleKeyPair keyPair,
    SimplePublicKey remotePublicKey,
  ) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// Alice initiates X3DH with Bob's prekey bundle.
  ///
  /// Steps:
  /// 1. Verify Bob's signed prekey signature (caller responsibility -- server should verify)
  /// 2. Generate ephemeral key pair
  /// 3. Compute 3 or 4 DH operations
  /// 4. Derive shared secret via HKDF
  ///
  /// Parameters:
  /// - [aliceIdentity]: Alice's long-term X25519 identity key pair
  /// - [bobIdentityKey]: Bob's X25519 identity public key
  /// - [bobSignedPrekey]: Bob's signed prekey public key
  /// - [bobOneTimePrekey]: Bob's one-time prekey public key (optional)
  /// - [aliceSigningKey]: Alice's Ed25519 signing key pair (for verification)
  ///
  /// Returns the shared secret and Alice's ephemeral public key.
  static Future<X3dhInitResult> initiate({
    required SimpleKeyPair aliceIdentity,
    required SimplePublicKey bobIdentityKey,
    required SimplePublicKey bobSignedPrekey,
    SimplePublicKey? bobOneTimePrekey,
  }) async {
    // Generate ephemeral key pair
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final alicePublic = await aliceIdentity.extractPublicKey();

    // DH1 = DH(alice_identity_private, bob_signed_prekey)
    final dh1 = await _dh(aliceIdentity, bobSignedPrekey);

    // DH2 = DH(alice_ephemeral_private, bob_identity_key)
    final dh2 = await _dh(ephemeral, bobIdentityKey);

    // DH3 = DH(alice_ephemeral_private, bob_signed_prekey)
    final dh3 = await _dh(ephemeral, bobSignedPrekey);

    // Concatenate DH outputs
    final capacity = 32 * 3 + (bobOneTimePrekey != null ? 32 : 0);
    final dhConcat = Uint8List(capacity);
    var offset = 0;
    dhConcat.setRange(offset, offset + 32, dh1);
    offset += 32;
    dhConcat.setRange(offset, offset + 32, dh2);
    offset += 32;
    dhConcat.setRange(offset, offset + 32, dh3);
    offset += 32;

    // DH4 = DH(alice_ephemeral_private, bob_one_time_prekey) [optional]
    if (bobOneTimePrekey != null) {
      final dh4 = await _dh(ephemeral, bobOneTimePrekey);
      dhConcat.setRange(offset, offset + 32, dh4);
    }

    // Derive shared secret via HKDF
    final sharedSecret = await x3dhKdf(dhConcat);

    return X3dhInitResult(
      sharedSecret: sharedSecret,
      ephemeralPublic: ephemeralPublic,
      identityPublic: alicePublic,
    );
  }

  /// Bob responds to Alice's X3DH initiation.
  ///
  /// Computes the same DH operations from Bob's perspective using his
  /// private keys and Alice's public keys received in the message header.
  ///
  /// Parameters:
  /// - [bobIdentity]: Bob's long-term X25519 identity key pair
  /// - [bobSignedPrekey]: Bob's signed prekey key pair (private + public)
  /// - [bobOneTimePrekey]: Bob's one-time prekey key pair (optional)
  /// - [aliceIdentityKey]: Alice's X25519 identity public key
  /// - [aliceEphemeralKey]: Alice's ephemeral public key from the initial message
  ///
  /// Returns the 32-byte shared secret.
  static Future<Uint8List> respond({
    required SimpleKeyPair bobIdentity,
    required SimpleKeyPair bobSignedPrekey,
    SimpleKeyPair? bobOneTimePrekey,
    required SimplePublicKey aliceIdentityKey,
    required SimplePublicKey aliceEphemeralKey,
  }) async {
    // DH1 = DH(bob_signed_prekey_private, alice_identity_public)
    final dh1 = await _dh(bobSignedPrekey, aliceIdentityKey);

    // DH2 = DH(bob_identity_private, alice_ephemeral_public)
    final dh2 = await _dh(bobIdentity, aliceEphemeralKey);

    // DH3 = DH(bob_signed_prekey_private, alice_ephemeral_public)
    final dh3 = await _dh(bobSignedPrekey, aliceEphemeralKey);

    // Concatenate DH outputs
    final capacity = 32 * 3 + (bobOneTimePrekey != null ? 32 : 0);
    final dhConcat = Uint8List(capacity);
    var offset = 0;
    dhConcat.setRange(offset, offset + 32, dh1);
    offset += 32;
    dhConcat.setRange(offset, offset + 32, dh2);
    offset += 32;
    dhConcat.setRange(offset, offset + 32, dh3);
    offset += 32;

    // DH4 = DH(bob_one_time_prekey_private, alice_ephemeral_public) [optional]
    if (bobOneTimePrekey != null) {
      final dh4 = await _dh(bobOneTimePrekey, aliceEphemeralKey);
      dhConcat.setRange(offset, offset + 32, dh4);
    }

    return x3dhKdf(dhConcat);
  }
}
