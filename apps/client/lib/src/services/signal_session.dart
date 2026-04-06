/// Double Ratchet session for per-message forward secrecy.
///
/// Implements the Signal Protocol Double Ratchet as specified at:
/// https://signal.org/docs/specifications/doubleratchet/
///
/// Matches the Rust implementation at `core/rust-core/src/signal/ratchet.rs`
/// and `core/rust-core/src/signal/session.rs`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'signal_protocol.dart';

/// An established encrypted session with a peer, containing the Double Ratchet
/// state machine.
///
/// Wire format for encrypted messages (matching Rust `session.rs`):
/// - header_len (4 LE)
/// - header (variable, currently always 40 bytes)
/// - ciphertext (remainder: nonce || encrypted_data || tag)
class SignalSession {
  static final _x25519 = X25519();

  /// Root key -- evolves with each DH ratchet step.
  Uint8List rootKey;

  /// Current sending chain key.
  Uint8List sendChainKey;

  /// Current receiving chain key (null until first message received).
  Uint8List? recvChainKey;

  /// Our current DH ratchet key pair.
  SimpleKeyPair sendRatchetKeyPair;

  /// Our current DH ratchet public key (cached for serialization).
  SimplePublicKey sendRatchetPublic;

  /// Peer's current DH ratchet public key (null until first message received).
  SimplePublicKey? recvRatchetKey;

  /// Number of messages sent in the current sending chain.
  int sendCounter;

  /// Number of messages received in the current receiving chain.
  int recvCounter;

  /// Number of messages sent in the previous sending chain (for header).
  int prevSendCounter;

  /// Skipped message keys for out-of-order decryption.
  /// Key: "${hex(ratchetPublicKey)}:$messageNumber" -> messageKey bytes
  Map<String, Uint8List> skippedKeys;

  /// Whether the session has completed its initial handshake.
  bool established;

  SignalSession._({
    required this.rootKey,
    required this.sendChainKey,
    this.recvChainKey,
    required this.sendRatchetKeyPair,
    required this.sendRatchetPublic,
    this.recvRatchetKey,
    this.sendCounter = 0,
    this.recvCounter = 0,
    this.prevSendCounter = 0,
    Map<String, Uint8List>? skippedKeys,
    this.established = true,
  }) : skippedKeys = skippedKeys ?? {};

  /// Initialize as Alice (the session initiator).
  ///
  /// Alice has performed X3DH and knows the shared secret. She also knows
  /// Bob's signed prekey (which serves as his initial ratchet public key).
  /// Alice immediately performs a DH ratchet step to establish her sending chain.
  ///
  /// Matches `RatchetState::init_alice()` in Rust.
  static Future<SignalSession> initAlice(
    Uint8List sharedSecret,
    SimplePublicKey bobRatchetPublic,
  ) async {
    // Generate Alice's first ratchet key pair
    final sendRatchetKeyPair = await _x25519.newKeyPair();
    final sendRatchetPublic = await sendRatchetKeyPair.extractPublicKey();

    // Perform the initial DH ratchet step
    final dhOutput = await _dh(sendRatchetKeyPair, bobRatchetPublic);
    final (rootKey, sendChainKey) = await kdfRk(sharedSecret, dhOutput);

    return SignalSession._(
      rootKey: rootKey,
      sendChainKey: sendChainKey,
      recvChainKey: null,
      sendRatchetKeyPair: sendRatchetKeyPair,
      sendRatchetPublic: sendRatchetPublic,
      recvRatchetKey: bobRatchetPublic,
      sendCounter: 0,
      recvCounter: 0,
      prevSendCounter: 0,
    );
  }

  /// Initialize as Bob (the session responder).
  ///
  /// Bob uses his signed prekey as the initial ratchet key pair. He does
  /// not perform a DH ratchet step until he receives Alice's first message.
  ///
  /// Matches `RatchetState::init_bob()` in Rust.
  static Future<SignalSession> initBob(
    Uint8List sharedSecret,
    SimpleKeyPair bobRatchetKeyPair,
  ) async {
    final bobRatchetPublic = await bobRatchetKeyPair.extractPublicKey();

    return SignalSession._(
      rootKey: sharedSecret,
      sendChainKey: Uint8List(32), // Not used until first DH ratchet step
      recvChainKey: null,
      sendRatchetKeyPair: bobRatchetKeyPair,
      sendRatchetPublic: bobRatchetPublic,
      recvRatchetKey: null,
      sendCounter: 0,
      recvCounter: 0,
      prevSendCounter: 0,
    );
  }

  /// Perform a single X25519 DH operation.
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

  /// Encrypt a plaintext message.
  ///
  /// Advances the sending chain, derives a message key, encrypts the
  /// plaintext with AES-256-GCM, and returns a self-contained wire-format
  /// blob: header_len (4 LE) || header (40) || ciphertext.
  ///
  /// Matches `encrypt_message()` in Rust `session.rs`.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    if (!established) {
      throw Exception('Session not established');
    }

    // Derive message key and advance chain
    final (newChainKey, messageKey) = await kdfCk(sendChainKey);
    sendChainKey = newChainKey;

    final header = MessageHeader(
      ratchetPublicKey: Uint8List.fromList(sendRatchetPublic.bytes),
      prevChainLength: prevSendCounter,
      messageNumber: sendCounter,
    );

    sendCounter++;

    final ad = header.serialize();
    final ciphertext = await encryptWithAd(messageKey, plaintext, ad);

    // Wire format: header_len (4 LE) || header || ciphertext
    final headerBytes = header.serialize();
    final headerLen = headerBytes.length;
    final wire = Uint8List(4 + headerLen + ciphertext.length);
    final bd = ByteData.sublistView(wire);
    bd.setUint32(0, headerLen, Endian.little);
    wire.setRange(4, 4 + headerLen, headerBytes);
    wire.setRange(4 + headerLen, wire.length, ciphertext);

    return wire;
  }

  /// Decrypt an encrypted message blob received from a peer.
  ///
  /// If the header contains a new ratchet public key, performs a DH ratchet
  /// step first. Handles out-of-order messages by checking skipped keys.
  ///
  /// Input format: header_len (4 LE) || header || ciphertext.
  /// Matches `decrypt_message()` in Rust `session.rs`.
  Future<Uint8List> decrypt(Uint8List data) async {
    if (!established) {
      throw Exception('Session not established');
    }

    if (data.length < 4) {
      throw Exception('Encrypted message too short');
    }

    final bd = ByteData.sublistView(data);
    final headerLen = bd.getUint32(0, Endian.little);

    if (data.length < 4 + headerLen) {
      throw Exception('Encrypted message shorter than declared header');
    }

    final header = MessageHeader.deserialize(
      Uint8List.sublistView(data, 4, 4 + headerLen),
    );
    final ciphertext = Uint8List.sublistView(data, 4 + headerLen);
    final ad = header.serialize();

    // Check skipped keys first
    final skipKey = _skippedKeyId(
      header.ratchetPublicKey,
      header.messageNumber,
    );
    if (skippedKeys.containsKey(skipKey)) {
      final messageKey = skippedKeys.remove(skipKey)!;
      return decryptWithAd(messageKey, ciphertext, ad);
    }

    // Check if we need a DH ratchet step
    final needDhRatchet =
        recvRatchetKey == null ||
        !_bytesEqual(
          Uint8List.fromList(recvRatchetKey!.bytes),
          header.ratchetPublicKey,
        );

    if (needDhRatchet) {
      // Skip any remaining messages in the current receiving chain
      if (recvChainKey != null) {
        await _skipMessageKeys(header.prevChainLength);
      }
      await _dhRatchetStep(
        SimplePublicKey(
          List<int>.from(header.ratchetPublicKey),
          type: KeyPairType.x25519,
        ),
      );
    }

    // Skip ahead to the message number if needed
    await _skipMessageKeys(header.messageNumber);

    // Derive message key and advance receiving chain
    if (recvChainKey == null) {
      throw Exception('No receiving chain key');
    }

    final (newChainKey, messageKey) = await kdfCk(recvChainKey!);
    recvChainKey = newChainKey;
    recvCounter++;

    return decryptWithAd(messageKey, ciphertext, ad);
  }

  /// Perform a DH ratchet step with a new peer ratchet public key.
  ///
  /// Matches `dh_ratchet_step()` in Rust `ratchet.rs`.
  Future<void> _dhRatchetStep(SimplePublicKey newPeerRatchetKey) async {
    prevSendCounter = sendCounter;
    sendCounter = 0;
    recvCounter = 0;

    recvRatchetKey = newPeerRatchetKey;

    // Derive new receiving chain from DH(our_current_private, their_new_public)
    final dhRecv = await _dh(sendRatchetKeyPair, newPeerRatchetKey);
    final (rootKey1, recvChainKey1) = await kdfRk(rootKey, dhRecv);
    rootKey = rootKey1;
    recvChainKey = recvChainKey1;

    // Generate new sending ratchet key pair
    sendRatchetKeyPair = await _x25519.newKeyPair();
    sendRatchetPublic = await sendRatchetKeyPair.extractPublicKey();

    // Derive new sending chain
    final dhSend = await _dh(sendRatchetKeyPair, newPeerRatchetKey);
    final (rootKey2, sendChainKey1) = await kdfRk(rootKey, dhSend);
    rootKey = rootKey2;
    sendChainKey = sendChainKey1;
  }

  /// Skip message keys up to (but not including) the target message number.
  ///
  /// Stores the skipped keys so out-of-order messages can still be decrypted.
  /// Matches `skip_message_keys()` in Rust `ratchet.rs`.
  Future<void> _skipMessageKeys(int until) async {
    if (recvCounter + maxSkip < until) {
      throw Exception(
        'Too many skipped messages (recv_counter=$recvCounter, target=$until)',
      );
    }

    if (recvChainKey != null) {
      while (recvCounter < until) {
        final (newCk, mk) = await kdfCk(recvChainKey!);
        final rk = recvRatchetKey != null
            ? Uint8List.fromList(recvRatchetKey!.bytes)
            : Uint8List(32);
        skippedKeys[_skippedKeyId(rk, recvCounter)] = mk;
        recvChainKey = newCk;
        recvCounter++;
      }
    }
  }

  /// Generate a unique key for the skipped keys map.
  static String _skippedKeyId(Uint8List ratchetPubKey, int messageNumber) {
    final hex = ratchetPubKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$hex:$messageNumber';
  }

  /// Compare two byte lists for equality.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Serialize session state to JSON for secure storage persistence.
  ///
  /// Note: We store the private key bytes for the ratchet key pair.
  /// These are persisted via [SecureKeyStore] (platform-specific secure storage).
  Future<Map<String, dynamic>> toJson() async {
    final sendPrivateBytes = await (sendRatchetKeyPair as SimpleKeyPairData)
        .extractPrivateKeyBytes();

    return {
      'root_key': _bytesToHex(rootKey),
      'send_chain_key': _bytesToHex(sendChainKey),
      'recv_chain_key': recvChainKey != null
          ? _bytesToHex(recvChainKey!)
          : null,
      'send_ratchet_private': _bytesToHex(Uint8List.fromList(sendPrivateBytes)),
      'send_ratchet_public': _bytesToHex(
        Uint8List.fromList(sendRatchetPublic.bytes),
      ),
      'recv_ratchet_key': recvRatchetKey != null
          ? _bytesToHex(Uint8List.fromList(recvRatchetKey!.bytes))
          : null,
      'send_counter': sendCounter,
      'recv_counter': recvCounter,
      'prev_send_counter': prevSendCounter,
      'established': established,
      'skipped_keys': skippedKeys.map((k, v) => MapEntry(k, _bytesToHex(v))),
    };
  }

  /// Deserialize session state from JSON.
  static SignalSession fromJson(Map<String, dynamic> json) {
    final sendPrivateBytes = _hexToBytes(
      json['send_ratchet_private'] as String,
    );
    final sendPublicBytes = _hexToBytes(json['send_ratchet_public'] as String);
    final sendPublic = SimplePublicKey(
      List<int>.from(sendPublicBytes),
      type: KeyPairType.x25519,
    );
    final sendKeyPair = SimpleKeyPairData(
      List<int>.from(sendPrivateBytes),
      publicKey: sendPublic,
      type: KeyPairType.x25519,
    );

    SimplePublicKey? recvRatchetKey;
    if (json['recv_ratchet_key'] != null) {
      final recvBytes = _hexToBytes(json['recv_ratchet_key'] as String);
      recvRatchetKey = SimplePublicKey(
        List<int>.from(recvBytes),
        type: KeyPairType.x25519,
      );
    }

    Uint8List? recvChainKey;
    if (json['recv_chain_key'] != null) {
      recvChainKey = _hexToBytes(json['recv_chain_key'] as String);
    }

    final skippedKeysRaw =
        (json['skipped_keys'] as Map<String, dynamic>?) ?? {};
    final skippedKeys = skippedKeysRaw.map(
      (k, v) => MapEntry(k, _hexToBytes(v as String)),
    );

    return SignalSession._(
      rootKey: _hexToBytes(json['root_key'] as String),
      sendChainKey: _hexToBytes(json['send_chain_key'] as String),
      recvChainKey: recvChainKey,
      sendRatchetKeyPair: sendKeyPair,
      sendRatchetPublic: sendPublic,
      recvRatchetKey: recvRatchetKey,
      sendCounter: json['send_counter'] as int,
      recvCounter: json['recv_counter'] as int,
      prevSendCounter: json['prev_send_counter'] as int,
      skippedKeys: skippedKeys,
      established: json['established'] as bool? ?? true,
    );
  }
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
