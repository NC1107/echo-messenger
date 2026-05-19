/// Convert between the server's canonical UUID string form and the
/// 16-byte raw form used in GRP2 sender-signature payloads (audit OQ-12).
///
/// The GRP2 wire format binds (conversation_id, message_id) into the
/// Ed25519 signature as 16 bytes each. The server stores both as
/// PostgreSQL `UUID` (which round-trips to the canonical
/// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` string form) and emits them
/// as strings in WebSocket frames. Both sides MUST agree byte-for-byte
/// on the 16-byte representation, so the parsing lives in one place.
library;

import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// Parse a canonical UUID string into its 16-byte raw form. Throws
/// [FormatException] on a malformed input — callers must surface that
/// to the user (or the audit-banner) rather than treating it as a
/// transient error, because a malformed UUID typically means the
/// server's wire format has changed in an incompatible way.
Uint8List uuidStringToBytes(String uuidString) {
  if (!Uuid.isValidUUID(fromString: uuidString)) {
    throw FormatException('Invalid UUID: $uuidString');
  }
  return Uint8List.fromList(Uuid.parse(uuidString, validate: false));
}

/// Format a 16-byte UUID as the canonical 8-4-4-4-12 string. Throws
/// [ArgumentError] when [bytes] isn't exactly 16 bytes long — every
/// UUID is 16 bytes and any other length is a programming error.
String uuidBytesToString(Uint8List bytes) {
  if (bytes.length != 16) {
    throw ArgumentError(
      'UUID bytes must be exactly 16 bytes, got ${bytes.length}',
    );
  }
  return Uuid.unparse(bytes);
}

/// Mint a fresh v4 UUID as 16 raw bytes. Used by the GRP2 send path
/// so the sender can bind a message_id into the signature payload
/// before the server has assigned the canonical id; the server then
/// respects the client-minted id when writing to `messages.id`.
Uint8List newUuidBytes() {
  return Uint8List.fromList(const Uuid().v4obj().toBytes());
}
