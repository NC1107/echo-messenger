/// Round-trip tests for the GRP2 UUID helper. The signature payload
/// in GRP2 binds (conversation_id, message_id) as raw 16-byte UUIDs,
/// so the sender's bytes-to-string output and the receiver's
/// string-to-bytes input have to agree byte-for-byte. Drift here
/// breaks the entire GRP2 verify path on the receiver side.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:echo_app/src/utils/uuid_bytes.dart';

void main() {
  group('uuid_bytes', () {
    test('newUuidBytes mints exactly 16 bytes', () {
      final bytes = newUuidBytes();
      expect(bytes.length, 16);
    });

    test('newUuidBytes round-trips through canonical string form', () {
      final bytes = newUuidBytes();
      final str = uuidBytesToString(bytes);
      final reparsed = uuidStringToBytes(str);
      expect(reparsed, bytes);
    });

    test('uuidStringToBytes matches Uuid.parse for canonical form', () {
      const canonical = '12345678-1234-4567-89ab-1234567890ab';
      final ours = uuidStringToBytes(canonical);
      final theirs = Uuid.parse(canonical);
      expect(ours, Uint8List.fromList(theirs));
    });

    test('uuidStringToBytes rejects malformed UUID', () {
      expect(
        () => uuidStringToBytes('not-a-uuid'),
        throwsA(isA<FormatException>()),
      );
    });

    test('uuidBytesToString rejects non-16-byte input', () {
      expect(
        () => uuidBytesToString(Uint8List(15)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => uuidBytesToString(Uint8List(17)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('minted UUIDs are not all-zero (random source wired up)', () {
      final bytes = newUuidBytes();
      expect(
        bytes.any((b) => b != 0),
        isTrue,
        reason: 'a fresh v4 UUID must have at least one non-zero byte',
      );
    });
  });
}
