/// Low-level cryptographic primitives for the Signal Protocol implementation.
///
/// Provides HKDF-based key derivation, AES-256-GCM encryption/decryption,
/// and message header serialization matching the Rust implementation at
/// `core/rust-core/src/signal/ratchet.rs`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// HKDF info string for the X3DH shared secret derivation.
/// Must match the Rust constant `X3DH_HKDF_INFO`.
const x3dhHkdfInfo = 'EchoSignalX3DH';

/// HKDF info string for the DH ratchet root key derivation.
/// Must match the Rust constant `RATCHET_KDF_INFO`.
const ratchetKdfInfo = 'EchoDoubleRatchet';

/// HKDF info/label for deriving a message key from a chain key.
/// Must match the Rust constant usage.
const messageKeyInfo = 'EchoMessageKey';

/// HKDF info/label for deriving the next chain key.
/// Must match the Rust constant usage.
const chainKeyInfo = 'EchoChainKey';

/// Seed byte used as IKM when deriving a message key from a chain key.
const int messageKeySeed = 0x01;

/// Seed byte used as IKM when deriving the next chain key.
const int chainKeySeed = 0x02;

/// Maximum number of skipped message keys to store per session.
/// Prevents memory exhaustion from a malicious peer.
const int maxSkip = 1000;

/// Derive a 32-byte shared secret from concatenated DH outputs via HKDF-SHA256.
///
/// Uses a 32-byte zero salt as specified by the Signal X3DH specification.
/// This matches the Rust `kdf()` function in `x3dh.rs`.
Future<Uint8List> x3dhKdf(Uint8List dhConcat) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final salt = Uint8List(32); // 32-byte zero salt
  final derived = await hkdf.deriveKey(
    secretKey: SecretKeyData(dhConcat),
    nonce: salt,
    info: x3dhHkdfInfo.codeUnits,
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// Derive new (rootKey, chainKey) from the current root key and a DH output.
///
/// Uses HKDF-SHA256 with rootKey as salt and dhOutput as IKM.
/// Outputs 64 bytes: first 32 = new root key, last 32 = new chain key.
/// This matches the Rust `kdf_rk()` function in `ratchet.rs`.
Future<(Uint8List, Uint8List)> kdfRk(
  Uint8List rootKey,
  Uint8List dhOutput,
) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKeyData(dhOutput),
    nonce: rootKey,
    info: ratchetKdfInfo.codeUnits,
  );
  final bytes = Uint8List.fromList(await derived.extractBytes());
  return (bytes.sublist(0, 32), bytes.sublist(32, 64));
}

/// Derive a message key and next chain key from the current chain key.
///
/// Returns (nextChainKey, messageKey).
/// - messageKey = HKDF(salt=chainKey, ikm=[MESSAGE_KEY_SEED], info="EchoMessageKey")
/// - nextChainKey = HKDF(salt=chainKey, ikm=[CHAIN_KEY_SEED], info="EchoChainKey")
///
/// This matches the Rust `kdf_ck()` function in `ratchet.rs`.
Future<(Uint8List, Uint8List)> kdfCk(Uint8List chainKey) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  // Derive message key
  final mkDerived = await hkdf.deriveKey(
    secretKey: SecretKeyData(Uint8List.fromList([messageKeySeed])),
    nonce: chainKey,
    info: messageKeyInfo.codeUnits,
  );
  final messageKey = Uint8List.fromList(await mkDerived.extractBytes());

  // Derive next chain key
  final ckDerived = await hkdf.deriveKey(
    secretKey: SecretKeyData(Uint8List.fromList([chainKeySeed])),
    nonce: chainKey,
    info: chainKeyInfo.codeUnits,
  );
  final nextChainKey = Uint8List.fromList(await ckDerived.extractBytes());

  return (nextChainKey, messageKey);
}

/// Encrypt plaintext with AES-256-GCM, using the serialized header as AAD.
///
/// Returns nonce (12 bytes) || ciphertext+tag.
/// This matches the Rust `encrypt_with_ad()` function.
Future<Uint8List> encryptWithAd(
  Uint8List key,
  Uint8List plaintext,
  Uint8List ad,
) async {
  final aesGcm = AesGcm.with256bits();
  final secretBox = await aesGcm.encrypt(
    plaintext,
    secretKey: SecretKeyData(key),
    aad: ad,
  );

  // Pack: nonce (12) || ciphertext || mac (16) -- matches Rust layout
  final result = Uint8List(
    secretBox.nonce.length +
        secretBox.cipherText.length +
        secretBox.mac.bytes.length,
  );
  var offset = 0;
  result.setRange(offset, offset + secretBox.nonce.length, secretBox.nonce);
  offset += secretBox.nonce.length;
  result.setRange(
    offset,
    offset + secretBox.cipherText.length,
    secretBox.cipherText,
  );
  offset += secretBox.cipherText.length;
  result.setRange(
    offset,
    offset + secretBox.mac.bytes.length,
    secretBox.mac.bytes,
  );

  return result;
}

/// Decrypt ciphertext with AES-256-GCM, verifying the AAD.
///
/// Input format: nonce (12 bytes) || ciphertext+tag.
/// This matches the Rust `decrypt_with_ad()` function.
Future<Uint8List> decryptWithAd(
  Uint8List key,
  Uint8List ciphertext,
  Uint8List ad,
) async {
  if (ciphertext.length < 12 + 16) {
    throw Exception(
      'Ciphertext too short for AES-GCM (need >= 28 bytes, got ${ciphertext.length})',
    );
  }

  final nonce = ciphertext.sublist(0, 12);
  final ct = ciphertext.sublist(12, ciphertext.length - 16);
  final mac = Mac(ciphertext.sublist(ciphertext.length - 16));

  final aesGcm = AesGcm.with256bits();
  final secretBox = SecretBox(ct, nonce: nonce, mac: mac);

  final plaintext = await aesGcm.decrypt(
    secretBox,
    secretKey: SecretKeyData(key),
    aad: ad,
  );

  return Uint8List.fromList(plaintext);
}

/// Message header attached to each encrypted message.
///
/// Contains the sender's current ratchet public key and counters needed
/// for the receiver to synchronize their ratchet state.
///
/// Wire layout: ratchet_public_key (32) || prev_chain_length (4 LE) || message_number (4 LE)
/// Total: 40 bytes. Matches the Rust `MessageHeader`.
class MessageHeader {
  /// Sender's current DH ratchet public key (32 bytes).
  final Uint8List ratchetPublicKey;

  /// Number of messages sent in the previous sending chain.
  final int prevChainLength;

  /// Message number within the current sending chain.
  final int messageNumber;

  MessageHeader({
    required this.ratchetPublicKey,
    required this.prevChainLength,
    required this.messageNumber,
  });

  /// Serialize to 40 bytes matching the Rust wire format.
  Uint8List serialize() {
    final out = Uint8List(40);
    out.setRange(0, 32, ratchetPublicKey);
    final bd = ByteData.sublistView(out);
    bd.setUint32(32, prevChainLength, Endian.little);
    bd.setUint32(36, messageNumber, Endian.little);
    return out;
  }

  /// Deserialize from bytes (must be >= 40 bytes).
  static MessageHeader deserialize(Uint8List data) {
    if (data.length < 40) {
      throw Exception(
        'MessageHeader data too short (need 40 bytes, got ${data.length})',
      );
    }
    final bd = ByteData.sublistView(data);
    return MessageHeader(
      ratchetPublicKey: Uint8List.fromList(data.sublist(0, 32)),
      prevChainLength: bd.getUint32(32, Endian.little),
      messageNumber: bd.getUint32(36, Endian.little),
    );
  }

  /// JSON serialization for SharedPreferences storage.
  Map<String, dynamic> toJson() => {
    'ratchet_public_key': _bytesToHex(ratchetPublicKey),
    'prev_chain_length': prevChainLength,
    'message_number': messageNumber,
  };

  static MessageHeader fromJson(Map<String, dynamic> json) => MessageHeader(
    ratchetPublicKey: _hexToBytes(json['ratchet_public_key'] as String),
    prevChainLength: json['prev_chain_length'] as int,
    messageNumber: json['message_number'] as int,
  );
}

/// Convert bytes to hex string for JSON serialization.
String _bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Convert hex string back to bytes.
Uint8List _hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
