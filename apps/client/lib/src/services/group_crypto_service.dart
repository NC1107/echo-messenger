/// AES-256-GCM group encryption service with per-member key distribution.
///
/// Each group conversation has a symmetric AES key shared by all members.
/// Instead of uploading the raw key to the server, the key is encrypted
/// individually for each member using their X25519 identity public key
/// (ECDH + HKDF + AES-GCM wrapping). The server only ever sees per-member
/// encrypted envelopes and cannot recover the plaintext group key.
///
/// Messages are encrypted with a random 12-byte nonce; the wire format is
/// `nonce(12) || ciphertext || tag(16)`, base64-encoded for transport.
///
/// Keys are cached in [SecureKeyStore] keyed by
/// `group_key_{conversationId}_{version}`.
library;

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/crypto_perf.dart';
import 'crypto_service.dart';
import 'secure_key_store.dart';

/// Prefix used to mark legacy group-encrypted payloads (no sender signature).
/// Receivers continue to accept this for backward compatibility at envelope
/// versions with `min_wire_version = 1`.
const groupEncryptedPrefix = 'GRP1:';

/// Prefix used to mark GRP2-format group-encrypted payloads. GRP2 wires
/// carry a per-message Ed25519 sender signature so any current OR former
/// member with the group key cannot forge messages as someone else
/// (audit OQ-1, OQ-12). Wire layout AFTER the prefix:
///
///     version_byte(1) || nonce(12) || ciphertext || tag(16) || sig(64)
///
/// Signature is Ed25519 over:
///
///     version_byte || conv_id(16 raw uuid bytes) || msg_id(16 raw uuid bytes)
///                  || nonce || ciphertext || tag
///
/// `conv_id` + `msg_id` are bound into the signature to prevent cross-
/// conversation replay and to give the sender a content-anchored commitment
/// the server cannot rewrite.
const groupEncryptedPrefixV2 = 'GRP2:';

/// Current GRP2 revision. Future revisions bump this byte without changing
/// the textual prefix so receivers can dispatch on the leading version byte.
const int groupEncryptedV2Version = 0x01;

/// Length of the Ed25519 signature appended to a GRP2 wire.
const int _ed25519SignatureLength = 64;

/// Thrown when a GRP2 sender signature fails to verify. Surfaced as a
/// distinct exception (and a distinct UI placeholder) from
/// [GroupEnvelopeUnwrapException] so users see "this message's author
/// can't be confirmed" rather than the generic "[Could not decrypt…]".
/// Audit OQ-1 + design §"Per-message authenticity".
class GroupSenderSignatureException implements Exception {
  final String reason;
  const GroupSenderSignatureException(this.reason);

  @override
  String toString() => 'GroupSenderSignatureException: $reason';
}

/// AES-256 key size in bytes. Used to structurally validate that a
/// candidate group key — whether unwrapped from a per-member envelope or
/// taken from the legacy plaintext-key migration path — is at least
/// shaped like an AES-256 key before we cache it and start encrypting
/// production messages with it. Audit P1-2 / MED-2.
const int _groupKeyBytesLength = 32;

/// Thrown when a group-key envelope cannot be unwrapped AND the legacy
/// plaintext-key fallback also fails the structural check (32 bytes of
/// AES-256-key shape). The caller is expected to return `null` from the
/// fetch path and let the UI surface a "rotate group key" affordance.
///
/// The previous behaviour at `group_crypto_service.dart:225` silently
/// cached the ciphertext blob as if it were the key, which produced an
/// endless stream of `[Could not decrypt…]` placeholders for every
/// message in the group with no signal that the actual problem was a
/// malformed envelope. Audit MED-2 / P1-2.
class GroupEnvelopeUnwrapException implements Exception {
  final String conversationId;
  final int keyVersion;
  final String reason;
  const GroupEnvelopeUnwrapException(
    this.conversationId,
    this.keyVersion,
    this.reason,
  );

  @override
  String toString() =>
      'GroupEnvelopeUnwrapException(conv=$conversationId, '
      'version=$keyVersion): $reason';
}

class GroupCryptoService {
  final String serverUrl;
  String _token = '';

  /// Reference to the CryptoService for identity key operations and
  /// per-user encryption/decryption (ECDH key wrapping).
  CryptoService? _cryptoService;

  /// In-memory cache: conversationId -> (key_version, raw key bytes,
  /// min_wire_version). Phase 2C extended the tuple with min_wire_version
  /// so the send path can dispatch GRP1 vs GRP2 without an extra server
  /// round-trip per message. Entries restored from `SecureKeyStore`
  /// default to min_wire_version=1 (existing pre-Phase-2 data); fresh
  /// entries from `fetchGroupKey` carry whatever the server returned.
  final Map<String, (int, Uint8List, int)> _keyCache = {};

  /// Groups known to not have encryption enabled. Prevents repeated 400
  /// requests against the server for plaintext groups.
  final Set<String> _unencryptedGroups = {};

  static final _aesGcm = AesGcm.with256bits();

  GroupCryptoService({required this.serverUrl});

  /// Set the CryptoService instance for identity key operations.
  void setCryptoService(CryptoService service) {
    _cryptoService = service;
  }

  /// Mark a group as unencrypted so [getGroupKey] short-circuits.
  void markUnencrypted(String conversationId) {
    _unencryptedGroups.add(conversationId);
  }

  /// Mark a group as encrypted (removes from the unencrypted set).
  void markEncrypted(String conversationId) {
    _unencryptedGroups.remove(conversationId);
  }

  void setToken(String token) {
    _token = token;
  }

  // -----------------------------------------------------------------------
  // Key generation
  // -----------------------------------------------------------------------

  /// Generate a random 32-byte AES-256 key, returned as base64.
  static String generateGroupKey() {
    final secretKey = SecretKeyData.random(length: 32);
    return base64Encode(secretKey.bytes);
  }

  // -----------------------------------------------------------------------
  // Encrypt / decrypt
  // -----------------------------------------------------------------------

  /// Encrypt [plaintext] with the given base64-encoded AES-256 key.
  ///
  /// Returns `GRP1:` prefix + base64(nonce(12) || ciphertext || tag(16)).
  static Future<String> encryptGroupMessage(
    String plaintext,
    String keyBase64,
  ) async {
    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);
    final plaintextBytes = utf8.encode(plaintext);

    final secretBox = await _aesGcm.encrypt(
      plaintextBytes,
      secretKey: secretKey,
    );

    // Wire format: nonce(12) || ciphertext || mac(16)
    final nonce = Uint8List.fromList(secretBox.nonce);
    final ciphertext = Uint8List.fromList(secretBox.cipherText);
    final mac = Uint8List.fromList(secretBox.mac.bytes);

    final wire = Uint8List(nonce.length + ciphertext.length + mac.length);
    wire.setRange(0, 12, nonce);
    wire.setRange(12, 12 + ciphertext.length, ciphertext);
    wire.setRange(12 + ciphertext.length, wire.length, mac);

    return '$groupEncryptedPrefix${base64Encode(wire)}';
  }

  /// Decrypt a group message produced by [encryptGroupMessage].
  ///
  /// [ciphertextWithPrefix] must start with `GRP1:`.
  static Future<String> decryptGroupMessage(
    String ciphertextWithPrefix,
    String keyBase64,
  ) async {
    if (!ciphertextWithPrefix.startsWith(groupEncryptedPrefix)) {
      throw const FormatException(
        'Not a group-encrypted message (missing prefix)',
      );
    }

    final b64 = ciphertextWithPrefix.substring(groupEncryptedPrefix.length);
    final wire = Uint8List.fromList(base64Decode(b64));

    if (wire.length < 12 + 16) {
      throw FormatException('Group ciphertext too short: ${wire.length} bytes');
    }

    final nonce = wire.sublist(0, 12);
    final ciphertext = wire.sublist(12, wire.length - 16);
    final macBytes = wire.sublist(wire.length - 16);

    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes));

    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: secretKey);

    return utf8.decode(plainBytes);
  }

  // -----------------------------------------------------------------------
  // GRP2 — Encrypt + sign (audit OQ-1, OQ-11, OQ-12)
  // -----------------------------------------------------------------------

  /// Build the signature payload bound to a GRP2 message. Lives as a
  /// helper because both [encryptGroupMessageV2] and
  /// [verifyAndDecryptGroupMessageV2] need to reproduce it byte-for-byte
  /// — any divergence between sign and verify breaks every message.
  ///
  /// Layout: `version_byte || conv_id(16) || msg_id(16) || nonce(12) ||
  /// ciphertext || tag(16)`. UUIDs are passed in as their 16-byte raw
  /// form (not the 36-char string form) so the signature payload is
  /// deterministic across UUID parsers.
  static Uint8List _grpV2SignaturePayload({
    required int version,
    required Uint8List conversationIdBytes,
    required Uint8List messageIdBytes,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
  }) {
    if (conversationIdBytes.length != 16) {
      throw ArgumentError(
        'conversationIdBytes must be 16 bytes (raw UUID), got '
        '${conversationIdBytes.length}',
      );
    }
    if (messageIdBytes.length != 16) {
      throw ArgumentError(
        'messageIdBytes must be 16 bytes (raw UUID), got '
        '${messageIdBytes.length}',
      );
    }
    final total =
        1 +
        conversationIdBytes.length +
        messageIdBytes.length +
        nonce.length +
        ciphertext.length +
        tag.length;
    final out = Uint8List(total);
    var offset = 0;
    out[offset++] = version & 0xFF;
    out.setRange(offset, offset + 16, conversationIdBytes);
    offset += 16;
    out.setRange(offset, offset + 16, messageIdBytes);
    offset += 16;
    out.setRange(offset, offset + 12, nonce);
    offset += 12;
    out.setRange(offset, offset + ciphertext.length, ciphertext);
    offset += ciphertext.length;
    out.setRange(offset, offset + tag.length, tag);
    return out;
  }

  /// Encrypt [plaintext] with a GRP2 wire frame and sign the result with
  /// the sender's Ed25519 device identity key.
  ///
  /// The `conversationId` + `messageId` UUIDs are bound into the
  /// signature so a hostile server cannot rewrite the (conv, msg)
  /// metadata without invalidating the signature. The sender mints the
  /// `messageId` locally; the server is expected to respect it on
  /// storage (this is a Phase 2C server-side change).
  ///
  /// Returns `GRP2:` + base64( version(1) || nonce(12) || ct || tag(16)
  /// || sig(64) ). Wire prefix dispatch lets receivers route this past
  /// the existing GRP1 decryption path without ambiguity.
  static Future<String> encryptGroupMessageV2({
    required String plaintext,
    required String keyBase64,
    required Uint8List conversationIdBytes,
    required Uint8List messageIdBytes,
    required SimpleKeyPair senderSigningKey,
  }) {
    // Nonce omitted => AesGcm draws one from the system CSPRNG.
    return _packGrp2Internal(
      plaintext: plaintext,
      keyBase64: keyBase64,
      conversationIdBytes: conversationIdBytes,
      messageIdBytes: messageIdBytes,
      senderSigningKey: senderSigningKey,
      nonceOverride: null,
    );
  }

  /// Test-only seam: pack a GRP2 wire with a caller-supplied nonce so the
  /// output is deterministic and can be compared byte-for-byte against
  /// the Rust reference implementation. Production code MUST go through
  /// [encryptGroupMessageV2] so the AES-GCM nonce comes from the system
  /// CSPRNG — reusing a nonce under the same key is catastrophic.
  ///
  /// Added for the cross-impl wire-compat test suite (audit P2-2). Lives
  /// in the same crate so the test doesn't have to fork the wire-format
  /// assembly and silently drift from production.
  @visibleForTesting
  static Future<String> packGrp2WithNonce({
    required String plaintext,
    required String keyBase64,
    required Uint8List conversationIdBytes,
    required Uint8List messageIdBytes,
    required SimpleKeyPair senderSigningKey,
    required Uint8List nonce,
  }) {
    return _packGrp2Internal(
      plaintext: plaintext,
      keyBase64: keyBase64,
      conversationIdBytes: conversationIdBytes,
      messageIdBytes: messageIdBytes,
      senderSigningKey: senderSigningKey,
      nonceOverride: nonce,
    );
  }

  static Future<String> _packGrp2Internal({
    required String plaintext,
    required String keyBase64,
    required Uint8List conversationIdBytes,
    required Uint8List messageIdBytes,
    required SimpleKeyPair senderSigningKey,
    required Uint8List? nonceOverride,
  }) async {
    final keyBytes = base64Decode(keyBase64);
    if (keyBytes.length != _groupKeyBytesLength) {
      throw ArgumentError(
        'GRP2 keyBase64 must decode to $_groupKeyBytesLength bytes, got '
        '${keyBytes.length}',
      );
    }
    if (nonceOverride != null && nonceOverride.length != 12) {
      throw ArgumentError(
        'GRP2 nonce override must be 12 bytes, got ${nonceOverride.length}',
      );
    }
    final secretKey = SecretKey(keyBytes);
    final plaintextBytes = utf8.encode(plaintext);

    final secretBox = await _aesGcm.encrypt(
      plaintextBytes,
      secretKey: secretKey,
      nonce: nonceOverride,
    );
    final nonce = Uint8List.fromList(secretBox.nonce);
    final ciphertext = Uint8List.fromList(secretBox.cipherText);
    final tag = Uint8List.fromList(secretBox.mac.bytes);

    final sigPayload = _grpV2SignaturePayload(
      version: groupEncryptedV2Version,
      conversationIdBytes: conversationIdBytes,
      messageIdBytes: messageIdBytes,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag,
    );
    final signature = await Ed25519().sign(
      sigPayload,
      keyPair: senderSigningKey,
    );
    final sigBytes = Uint8List.fromList(signature.bytes);
    if (sigBytes.length != _ed25519SignatureLength) {
      throw StateError(
        'Ed25519 signature must be $_ed25519SignatureLength bytes, got '
        '${sigBytes.length}',
      );
    }

    final wireLen =
        1 + nonce.length + ciphertext.length + tag.length + sigBytes.length;
    final wire = Uint8List(wireLen);
    var offset = 0;
    wire[offset++] = groupEncryptedV2Version & 0xFF;
    wire.setRange(offset, offset + nonce.length, nonce);
    offset += nonce.length;
    wire.setRange(offset, offset + ciphertext.length, ciphertext);
    offset += ciphertext.length;
    wire.setRange(offset, offset + tag.length, tag);
    offset += tag.length;
    wire.setRange(offset, offset + sigBytes.length, sigBytes);

    return '$groupEncryptedPrefixV2${base64Encode(wire)}';
  }

  /// Verify the sender signature on a GRP2 wire then decrypt the payload.
  ///
  /// Two-stage failure surface: signature failures throw
  /// [GroupSenderSignatureException] (rendered as "Could not verify
  /// sender"), AES-GCM failures throw the underlying cryptography
  /// exception (rendered as the existing "[Could not decrypt…]"). The
  /// caller's UI distinguishes the two — signature failure is more
  /// alarming and must not be confused with a key-out-of-sync state.
  ///
  /// `expectedConversationIdBytes` + `expectedMessageIdBytes` MUST be
  /// the same UUIDs the sender bound into the signature. The caller is
  /// responsible for plumbing them through from the WS frame metadata.
  static Future<String> verifyAndDecryptGroupMessageV2({
    required String ciphertextWithPrefix,
    required String keyBase64,
    required Uint8List expectedConversationIdBytes,
    required Uint8List expectedMessageIdBytes,
    required SimplePublicKey senderVerifyKey,
  }) async {
    if (!ciphertextWithPrefix.startsWith(groupEncryptedPrefixV2)) {
      throw const FormatException(
        'Not a GRP2 group-encrypted message (missing GRP2: prefix)',
      );
    }
    final b64 = ciphertextWithPrefix.substring(groupEncryptedPrefixV2.length);
    final wire = Uint8List.fromList(base64Decode(b64));

    // Minimum: version(1) + nonce(12) + tag(16) + sig(64) = 93 bytes
    // (ciphertext can be empty for a zero-byte plaintext).
    const minLen = 1 + 12 + 16 + _ed25519SignatureLength;
    if (wire.length < minLen) {
      throw FormatException('GRP2 wire too short: ${wire.length} bytes');
    }

    final version = wire[0];
    if (version != groupEncryptedV2Version) {
      // Unknown future GRP2 revision. We fail loud so receivers don't
      // silently produce garbage when they meet a v2 they don't know yet.
      throw FormatException(
        'Unsupported GRP2 revision: 0x${version.toRadixString(16)}',
      );
    }

    final nonce = wire.sublist(1, 13);
    final sigStart = wire.length - _ed25519SignatureLength;
    final tagStart = sigStart - 16;
    final ciphertext = wire.sublist(13, tagStart);
    final tag = wire.sublist(tagStart, sigStart);
    final signatureBytes = wire.sublist(sigStart);

    // Verify the sender signature BEFORE running AEAD. Catching a forged
    // signature early avoids paying the AEAD cost and prevents a
    // timing channel that could leak whether AEAD passed independently.
    final sigPayload = _grpV2SignaturePayload(
      version: version,
      conversationIdBytes: expectedConversationIdBytes,
      messageIdBytes: expectedMessageIdBytes,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag,
    );
    final signature = Signature(signatureBytes, publicKey: senderVerifyKey);
    final sigOk = await Ed25519().verify(sigPayload, signature: signature);
    if (!sigOk) {
      throw const GroupSenderSignatureException(
        'Ed25519 sender signature did not verify against the expected '
        'sender public key',
      );
    }

    final keyBytes = base64Decode(keyBase64);
    if (keyBytes.length != _groupKeyBytesLength) {
      throw FormatException(
        'GRP2 keyBase64 must decode to $_groupKeyBytesLength bytes, got '
        '${keyBytes.length}',
      );
    }
    final secretKey = SecretKey(keyBytes);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(tag));
    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    return utf8.decode(plainBytes);
  }

  // -----------------------------------------------------------------------
  // Key management (fetch / cache / rotate)
  // -----------------------------------------------------------------------

  /// Get the group key for [conversationId], using the in-memory cache first,
  /// then falling back to [SecureKeyStore], and finally fetching from the
  /// server.
  ///
  /// Returns `(version, keyBase64)` or null if unavailable.
  Future<(int, String)?> getGroupKey(String conversationId) async {
    // Skip server call for groups known to be unencrypted
    if (_unencryptedGroups.contains(conversationId)) return null;

    // 1. In-memory cache
    if (_keyCache.containsKey(conversationId)) {
      final (version, bytes, _) = _keyCache[conversationId]!;
      return (version, base64Encode(bytes));
    }

    // 2. Secure storage
    final store = SecureKeyStore.instance;
    final allEntries = await store.readAll();
    final prefix = 'group_key_${conversationId}_';
    int? bestVersion;
    String? bestKey;
    for (final entry in allEntries.entries) {
      if (entry.key.startsWith(prefix)) {
        final vStr = entry.key.substring(prefix.length);
        final v = int.tryParse(vStr);
        if (v != null && (bestVersion == null || v > bestVersion)) {
          bestVersion = v;
          bestKey = entry.value;
        }
      }
    }
    if (bestVersion != null && bestKey != null) {
      // Pre-Phase-2C disk entries have no recorded min_wire_version;
      // default to 1 (GRP1). A subsequent fetchGroupKey will overwrite
      // the cache with the server's authoritative value.
      _keyCache[conversationId] = (
        bestVersion,
        Uint8List.fromList(base64Decode(bestKey)),
        1,
      );
      return (bestVersion, bestKey);
    }

    // 3. Fetch from server
    return fetchGroupKey(conversationId);
  }

  /// Phase 2C: read the cached `min_wire_version` for a conversation.
  /// Returns null if no key is cached. Callers SHOULD prime the cache
  /// via [getGroupKey] before reading this; the value is only correct
  /// for the current envelope (rotations bump it).
  ///
  /// Send path dispatches GRP1 vs GRP2 based on this value: >= 2 means
  /// "this envelope rejects GRP1 wires; you MUST send GRP2".
  int? cachedMinWireVersion(String conversationId) {
    final entry = _keyCache[conversationId];
    if (entry == null) return null;
    return entry.$3;
  }

  /// Test-only seam: prime the cache directly for [conversationId]
  /// without going through HTTP. Production code never calls this;
  /// tests use it to set up Phase 2C dispatch scenarios.
  @visibleForTesting
  void primeCacheForTest(
    String conversationId, {
    required int version,
    required String keyBase64,
    int minWireVersion = 1,
  }) {
    final bytes = Uint8List.fromList(base64Decode(keyBase64));
    _keyCache[conversationId] = (version, bytes, minWireVersion);
  }

  /// Fetch the latest group key from the server and cache it.
  ///
  /// The server returns a per-member encrypted envelope. We decrypt it using
  /// our identity private key to recover the raw AES group key.
  ///
  /// Returns `(version, keyBase64)` or null on failure.
  Future<(int, String)?> fetchGroupKey(String conversationId) async {
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys/latest'),
        headers: {'Authorization': 'Bearer $_token'},
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[GroupCrypto] Failed to fetch key for $conversationId: '
          '${response.statusCode}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final encryptedKey = data['encrypted_key'] as String;
      final version = data['key_version'] as int;
      // Phase 2A added min_wire_version to the envelope response. Older
      // servers won't send it; default to 1 (legacy GRP1-only) so
      // Phase 2C dispatch is conservative against unknown servers.
      final minWireVersion = (data['min_wire_version'] as int?) ?? 1;

      // Try to decrypt the envelope using our identity key.
      // If _cryptoService is available, the encrypted_key is a per-member
      // envelope that must be unwrapped. If not, assume legacy plaintext key.
      //
      // Audit P1-2: whichever branch produces the candidate key, validate
      // it is 32 bytes (AES-256 key size) before caching. Pre-fix, an
      // unwrap failure would silently cache the ~96-byte ciphertext blob
      // as if it were the key, producing endless decrypt failures on
      // every subsequent group message with no signal that the actual
      // problem was a malformed envelope.
      String rawKeyB64;
      if (_cryptoService != null && encryptedKey != '__envelope__') {
        try {
          final rawKeyBytes = await _cryptoService!.decryptFromUser(
            encryptedKey,
          );
          rawKeyB64 = base64Encode(rawKeyBytes);
        } catch (e) {
          // Fallback: treat as legacy plaintext key (migration path).
          // We accept this only if the structural check below confirms
          // the bytes are AES-256-key-shaped; an envelope ciphertext
          // would not pass.
          debugPrint(
            '[GroupCrypto] Envelope decrypt failed, trying as legacy: $e',
          );
          rawKeyB64 = encryptedKey;
        }
      } else {
        rawKeyB64 = encryptedKey;
      }

      assertGroupKeyShape(conversationId, version, rawKeyB64);
      await _cacheKey(
        conversationId,
        version,
        rawKeyB64,
        minWireVersion: minWireVersion,
      );
      return (version, rawKeyB64);
    } on GroupEnvelopeUnwrapException catch (e) {
      // Typed structural failure — log and return null so the UI sees the
      // group as "no key available" instead of caching a known-bad key.
      debugPrint('[GroupCrypto] $e');
      return null;
    } catch (e) {
      debugPrint('[GroupCrypto] fetchGroupKey error: $e');
      return null;
    }
  }

  /// Validate that `rawKeyB64` is a base64 string that decodes to exactly
  /// 32 bytes — the only shape that can be an AES-256 group key. Throws
  /// [GroupEnvelopeUnwrapException] when the structural check fails so
  /// the caller can short-circuit without caching a garbage key.
  ///
  /// This is the audit P1-2 sanity check. It does NOT prove the key is
  /// the *right* key for this group (symmetric crypto has no per-key
  /// verifier), but it does rule out the specific footgun where an
  /// envelope-ciphertext blob silently gets cached as a key.
  @visibleForTesting
  void assertGroupKeyShape(
    String conversationId,
    int keyVersion,
    String rawKeyB64,
  ) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(rawKeyB64);
    } catch (_) {
      throw GroupEnvelopeUnwrapException(
        conversationId,
        keyVersion,
        'candidate key is not valid base64',
      );
    }
    if (bytes.length != _groupKeyBytesLength) {
      throw GroupEnvelopeUnwrapException(
        conversationId,
        keyVersion,
        'candidate key has wrong length: ${bytes.length} bytes '
        '(expected $_groupKeyBytesLength). Likely an envelope-ciphertext '
        'blob slipped through the unwrap-failure fallback.',
      );
    }
  }

  /// Fetch the current group members from the server and rotate the AES
  /// group key on their behalf (#656).
  ///
  /// Used by the WS event handler when the server signals
  /// `group_key_rotation_requested` — typically right after another member is
  /// kicked, leaves, or is banned. We:
  ///
  /// 1. Drop our cached/persisted material for the old version (so we cannot
  ///    accidentally encrypt with the now-revoked key).
  /// 2. Pull the live member roster from `/api/groups/{id}` and resolve each
  ///    member's identity public key.
  /// 3. Generate a fresh 256-bit AES key, wrap it for each remaining member,
  ///    and POST the envelopes back at `keyVersion`.
  ///
  /// Race semantics: any number of members may attempt rotation in parallel.
  /// The server enforces `(conversation_id, key_version)` UNIQUE on
  /// `group_keys`, so only the first writer wins (201). Losers receive 409
  /// and short-circuit by simply dropping their candidate key — they will
  /// fetch the winning envelope on their next `getGroupKey` call.
  ///
  /// TODO(#658): leader election + recovery from partial rotations.
  /// Today this is "first writer wins" with no liveness guarantee — if every
  /// online member crashes mid-rotation the group is wedged until someone
  /// retries.
  Future<int?> performRotation(
    String conversationId,
    int keyVersion, {
    required Future<List<Map<String, dynamic>>> Function() fetchMembers,
    required Future<Uint8List?> Function(String userId) fetchIdentityKey,
    Future<bool> Function(String userId)? hasIdentityKeyChanged,
    String? selfUserId,
    String triggeredByEvent = 'unspecified',
  }) {
    // Audit P1-4: timeline event captures the full rotation cost (member
    // fetch + N ECDH envelope wraps + server POST). Rotation is rare in
    // steady state but expensive when it fires.
    return timedCryptoOp(
      'GroupCryptoService.performRotation',
      () => _performRotationImpl(
        conversationId,
        keyVersion,
        fetchMembers: fetchMembers,
        fetchIdentityKey: fetchIdentityKey,
        hasIdentityKeyChanged: hasIdentityKeyChanged,
        selfUserId: selfUserId,
        triggeredByEvent: triggeredByEvent,
      ),
      args: {'conversation': conversationId, 'keyVersion': keyVersion},
    );
  }

  Future<int?> _performRotationImpl(
    String conversationId,
    int keyVersion, {
    required Future<List<Map<String, dynamic>>> Function() fetchMembers,
    required Future<Uint8List?> Function(String userId) fetchIdentityKey,
    Future<bool> Function(String userId)? hasIdentityKeyChanged,
    String? selfUserId,
    required String triggeredByEvent,
  }) async {
    // Drop the stale key first so we never encrypt with the now-revoked
    // material on the next outgoing message — even if we cannot finish the
    // rotation right now (no CryptoService wired yet, or no envelopes
    // built), we must NOT keep the old key around. A stale-cache leak is a
    // correctness bug; a missing envelope is just a refetch.
    await _purgeKey(conversationId);

    if (_cryptoService == null) {
      debugPrint('[GroupCrypto] performRotation: no CryptoService set');
      return null;
    }

    final members = await fetchMembers();
    final newKeyBytes = Uint8List.fromList(base64Decode(generateGroupKey()));
    final newKeyB64 = base64Encode(newKeyBytes);

    // Fetch all identity keys concurrently. The previous serial for-loop
    // was O(N) round-trips before any envelope could be built — a
    // 100-member group took 5–10s on mobile. Future.wait parallelises
    // the N requests; the server's /api/keys/bundle endpoint is per-user
    // but the calls overlap on the wire so the wall time collapses to
    // roughly one RTT regardless of N. (TD-1 in TECHNICAL_DEBT.md.)
    final userIds = members
        .map((m) => m['user_id'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toList();
    final identityKeys = await Future.wait(userIds.map(fetchIdentityKey));

    // TD-21: if the rotator's own identity key is unavailable (e.g.
    // keyring locked, secure storage migration in flight), uploading
    // envelopes that exclude self would leave us unable to decrypt
    // anything we send in this group until the next rotation re-
    // includes us. Hard-abort so the caller can retry once the
    // keyring is unlocked. Other members with null keys still get
    // skipped further down — they'll be included in the next rotation
    // once they publish.
    if (selfUserId != null) {
      for (var i = 0; i < userIds.length; i++) {
        if (userIds[i] == selfUserId && identityKeys[i] == null) {
          debugPrint(
            '[GroupCrypto] performRotation aborted: local identity '
            'key unavailable (keyring locked?). Retry when crypto '
            'is ready.',
          );
          return null;
        }
      }
    }

    // TD-4: TOFU bypass guard. fetchPeerIdentityKey(forceRefresh: true)
    // silently trusts whatever the server returned, so wrapping the
    // group secret under a changed identity key would hand a fresh
    // envelope to a key the user has never confirmed. Abort the
    // rotation when any participant's TOFU flag is set — admins can
    // acknowledge the change in the chat header and retry. Skipped
    // when the caller didn't supply the checker (preserves the legacy
    // performRotation contract).
    if (hasIdentityKeyChanged != null) {
      final changedFlags = await Future.wait(
        userIds.map(hasIdentityKeyChanged),
      );
      final changedUsers = <String>[
        for (var i = 0; i < userIds.length; i++)
          if (changedFlags[i]) userIds[i],
      ];
      if (changedUsers.isNotEmpty) {
        debugPrint(
          '[GroupCrypto] performRotation aborted: identity key '
          'changed for ${changedUsers.join(', ')} (TOFU flag set). '
          'Acknowledge the change and retry.',
        );
        return null;
      }
    }

    final envelopes = <Map<String, dynamic>>[];
    for (var i = 0; i < userIds.length; i++) {
      final userId = userIds[i];
      final identityKey = identityKeys[i];
      if (identityKey == null) {
        debugPrint(
          '[GroupCrypto] performRotation: missing identity key for $userId',
        );
        continue;
      }
      final wrapped = await _cryptoService!.encryptForUser(
        newKeyBytes,
        identityKey,
      );
      envelopes.add({'user_id': userId, 'encrypted_key': wrapped});
    }

    if (envelopes.isEmpty) {
      debugPrint('[GroupCrypto] performRotation: no envelopes built');
      return null;
    }

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'key_version': keyVersion,
          'envelopes': envelopes,
          'triggered_by_event': triggeredByEvent,
        }),
      );

      if (response.statusCode == 409) {
        // Another member raced us and won. Drop our candidate key — the
        // server-broadcast `group_key_rotated` event will trigger a refetch.
        debugPrint(
          '[GroupCrypto] performRotation: lost race (409); '
          'will fetch winning envelope',
        );
        return null;
      }

      if (response.statusCode != 201) {
        debugPrint(
          '[GroupCrypto] performRotation upload failed: '
          '${response.statusCode} ${response.body}',
        );
        return null;
      }

      await _cacheKey(conversationId, keyVersion, newKeyB64);
      return keyVersion;
    } catch (e) {
      debugPrint('[GroupCrypto] performRotation error: $e');
      return null;
    }
  }

  /// Generate a new group key and upload per-member encrypted envelopes.
  ///
  /// For each group member, the raw AES key is encrypted using their identity
  /// public key via ECDH + HKDF + AES-GCM (CryptoService.encryptForUser).
  /// The server never sees the plaintext key.
  ///
  /// Returns the new version number, or null on failure.
  Future<int?> rotateGroupKey(
    String conversationId,
    List<Map<String, dynamic>> members, {
    String triggeredByEvent = 'unspecified',
  }) async {
    if (_cryptoService == null) {
      debugPrint('[GroupCrypto] Cannot rotate key: no CryptoService set');
      return null;
    }

    // Determine next version
    final current = await getGroupKey(conversationId);
    final nextVersion = current != null ? current.$1 + 1 : 1;

    final newKey = generateGroupKey();
    final newKeyBytes = Uint8List.fromList(base64Decode(newKey));

    // Build per-member envelopes
    final envelopes = <Map<String, dynamic>>[];
    for (final member in members) {
      final userId = member['user_id'] as String;
      final identityKeyB64 = member['identity_key'] as String?;

      if (identityKeyB64 == null) {
        debugPrint('[GroupCrypto] Skipping member $userId: no identity key');
        continue;
      }

      final identityKeyBytes = base64Decode(identityKeyB64);
      final encryptedEnvelope = await _cryptoService!.encryptForUser(
        newKeyBytes,
        Uint8List.fromList(identityKeyBytes),
      );

      envelopes.add({'user_id': userId, 'encrypted_key': encryptedEnvelope});
    }

    if (envelopes.isEmpty) {
      debugPrint('[GroupCrypto] No valid envelopes to upload');
      return null;
    }

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/$conversationId/keys'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'key_version': nextVersion,
          'envelopes': envelopes,
          'triggered_by_event': triggeredByEvent,
        }),
      );

      if (response.statusCode != 201) {
        debugPrint(
          '[GroupCrypto] Failed to upload key: '
          '${response.statusCode} ${response.body}',
        );
        return null;
      }

      await _cacheKey(conversationId, nextVersion, newKey);
      return nextVersion;
    } catch (e) {
      debugPrint('[GroupCrypto] rotateGroupKey error: $e');
      return null;
    }
  }

  /// Invalidate the cached key for a conversation so the next call to
  /// [getGroupKey] fetches a fresh copy from the server.
  Future<void> invalidateCache(String conversationId) async {
    _keyCache.remove(conversationId);
    // We keep secure-storage entries around for offline decryption of
    // older messages, but clear the in-memory cache so we re-fetch.
  }

  /// Clear all group keys (for logout).
  Future<void> clearAll() async {
    _keyCache.clear();
    _unencryptedGroups.clear();
    final store = SecureKeyStore.instance;
    final allEntries = await store.readAll();
    for (final key in allEntries.keys) {
      if (key.startsWith('group_key_')) {
        await store.delete(key);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  Future<void> _cacheKey(
    String conversationId,
    int version,
    String keyBase64, {
    int minWireVersion = 1,
  }) async {
    final bytes = Uint8List.fromList(base64Decode(keyBase64));
    _keyCache[conversationId] = (version, bytes, minWireVersion);

    final store = SecureKeyStore.instance;
    await store.write('group_key_${conversationId}_$version', keyBase64);
  }

  /// Public alias for [_purgeKey] used by the group recovery banner
  /// (Phase 4). When the user taps "Refresh key" because messages are
  /// rendering as "[Could not decrypt - waiting for group key]", the
  /// chat panel calls this then [getGroupKey] to pull a fresh envelope
  /// from the server. We do NOT auto-rotate; we just dump the local
  /// cache and re-read whatever the server currently advertises.
  Future<void> dropCachedKey(String conversationId) =>
      _purgeKey(conversationId);

  /// Drop every cached/persisted key for [conversationId] across all
  /// versions. Used during rotation (#656) so a kicked member who still has
  /// the old key cannot inject ciphertext we would encrypt for them.
  Future<void> _purgeKey(String conversationId) async {
    _keyCache.remove(conversationId);
    final store = SecureKeyStore.instance;
    final allEntries = await store.readAll();
    final prefix = 'group_key_${conversationId}_';
    for (final key in allEntries.keys) {
      if (key.startsWith(prefix)) {
        await store.delete(key);
      }
    }
  }
}
