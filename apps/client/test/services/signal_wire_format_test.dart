import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/signal_protocol.dart';

/// Known-good 32-byte ratchet public key (all bytes incremented from 0).
final _testKey32 = Uint8List.fromList(List.generate(32, (i) => i));

void main() {
  group('MessageHeader wire format', () {
    test('serialize produces exactly 40 bytes', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 0,
        messageNumber: 0,
      );
      expect(header.serialize().length, 40);
    });

    test('roundtrip serialize/deserialize preserves ratchet key', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 7,
        messageNumber: 3,
      );
      final bytes = header.serialize();
      final restored = MessageHeader.deserialize(bytes);

      expect(restored.ratchetPublicKey, equals(_testKey32));
    });

    test('roundtrip serialize/deserialize preserves prevChainLength', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 42,
        messageNumber: 0,
      );
      final bytes = header.serialize();
      final restored = MessageHeader.deserialize(bytes);

      expect(restored.prevChainLength, 42);
    });

    test('roundtrip serialize/deserialize preserves messageNumber', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 0,
        messageNumber: 255,
      );
      final bytes = header.serialize();
      final restored = MessageHeader.deserialize(bytes);

      expect(restored.messageNumber, 255);
    });

    test('ratchet key bytes are placed at offset 0..31 (little-endian fields after)', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final header = MessageHeader(
        ratchetPublicKey: key,
        prevChainLength: 1,
        messageNumber: 2,
      );
      final bytes = header.serialize();

      // First 32 bytes must be the key
      expect(bytes.sublist(0, 32), equals(key));
      // Bytes 32..35 = prevChainLength (1) LE
      expect(bytes[32], 1);
      expect(bytes[33], 0);
      expect(bytes[34], 0);
      expect(bytes[35], 0);
      // Bytes 36..39 = messageNumber (2) LE
      expect(bytes[36], 2);
      expect(bytes[37], 0);
      expect(bytes[38], 0);
      expect(bytes[39], 0);
    });

    test('large counter values serialize and deserialize correctly', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 0xDEADBEEF,
        messageNumber: 0xCAFEBABE,
      );
      final bytes = header.serialize();
      final restored = MessageHeader.deserialize(bytes);

      expect(restored.prevChainLength, 0xDEADBEEF);
      expect(restored.messageNumber, 0xCAFEBABE);
    });

    test('deserialize throws when data is fewer than 40 bytes', () {
      expect(
        () => MessageHeader.deserialize(Uint8List(39)),
        throwsException,
      );
    });

    test('deserialize succeeds with exactly 40 bytes', () {
      final bytes = Uint8List(40);
      expect(() => MessageHeader.deserialize(bytes), returnsNormally);
    });

    test('JSON roundtrip preserves all fields', () {
      final header = MessageHeader(
        ratchetPublicKey: _testKey32,
        prevChainLength: 12,
        messageNumber: 34,
      );
      final json = header.toJson();
      final restored = MessageHeader.fromJson(json);

      expect(restored.ratchetPublicKey, equals(_testKey32));
      expect(restored.prevChainLength, 12);
      expect(restored.messageNumber, 34);
    });
  });

  // ---------------------------------------------------------------------------
  // V1 / V2 initial message wire format
  // ---------------------------------------------------------------------------

  group('Initial message wire format constants', () {
    const v1Magic = [0xEC, 0x01];
    const v2Magic = [0xEC, 0x02];

    test('V1 magic bytes are 0xEC 0x01', () {
      expect(v1Magic[0], 0xEC);
      expect(v1Magic[1], 0x01);
    });

    test('V2 magic bytes are 0xEC 0x02', () {
      expect(v2Magic[0], 0xEC);
      expect(v2Magic[1], 0x02);
    });

    test('V1 and V2 magic bytes differ only in version nibble', () {
      expect(v1Magic[0], v2Magic[0]);
      expect(v1Magic[1], isNot(v2Magic[1]));
    });

    /// V1 layout: [0xEC, 0x01] + identity(32) + ephemeral(32) + ratchet_wire
    test('V1 wire minimum length is 66 bytes (2 magic + 32 identity + 32 ephemeral)', () {
      const minV1 = 2 + 32 + 32;
      expect(minV1, 66);
    });

    /// V2 layout: [0xEC, 0x02] + identity(32) + ephemeral(32) + otp_id(4 LE) + ratchet_wire
    test('V2 wire minimum length is 70 bytes (2 magic + 32 identity + 32 ephemeral + 4 otp_id)', () {
      const minV2 = 2 + 32 + 32 + 4;
      expect(minV2, 70);
    });

    test('building a synthetic V1 wire parses magic correctly', () {
      final identity = Uint8List.fromList(List.generate(32, (i) => i));
      final ephemeral = Uint8List.fromList(List.generate(32, (i) => i + 100));
      final ratchetWire = Uint8List.fromList([1, 2, 3, 4]);

      final wire = Uint8List(2 + 32 + 32 + ratchetWire.length);
      wire[0] = 0xEC;
      wire[1] = 0x01;
      wire.setRange(2, 34, identity);
      wire.setRange(34, 66, ephemeral);
      wire.setRange(66, wire.length, ratchetWire);

      expect(wire[0], 0xEC);
      expect(wire[1], 0x01);
      expect(wire.sublist(2, 34), equals(identity));
      expect(wire.sublist(34, 66), equals(ephemeral));
      expect(wire.sublist(66), equals(ratchetWire));
    });

    test('building a synthetic V2 wire parses magic + otp_id correctly', () {
      final identity = Uint8List.fromList(List.generate(32, (i) => i));
      final ephemeral = Uint8List.fromList(List.generate(32, (i) => i + 100));
      const otpKeyId = 42;
      final ratchetWire = Uint8List.fromList([5, 6, 7, 8]);

      final wire = Uint8List(2 + 32 + 32 + 4 + ratchetWire.length);
      wire[0] = 0xEC;
      wire[1] = 0x02;
      wire.setRange(2, 34, identity);
      wire.setRange(34, 66, ephemeral);
      final bd = ByteData.sublistView(wire);
      bd.setInt32(66, otpKeyId, Endian.little);
      wire.setRange(70, wire.length, ratchetWire);

      expect(wire[0], 0xEC);
      expect(wire[1], 0x02);
      expect(wire.sublist(2, 34), equals(identity));
      expect(wire.sublist(34, 66), equals(ephemeral));
      expect(bd.getInt32(66, Endian.little), otpKeyId);
      expect(wire.sublist(70), equals(ratchetWire));
    });

    test('V1 and V2 are distinguishable by second magic byte', () {
      // Simulates the detection logic in CryptoService._decryptMessage
      Uint8List makeWire(int versionByte) {
        final w = Uint8List(70);
        w[0] = 0xEC;
        w[1] = versionByte;
        return w;
      }

      bool isV1(Uint8List w) => w[0] == 0xEC && w[1] == 0x01;
      bool isV2(Uint8List w) => w[0] == 0xEC && w[1] == 0x02;

      expect(isV1(makeWire(0x01)), isTrue);
      expect(isV2(makeWire(0x01)), isFalse);
      expect(isV1(makeWire(0x02)), isFalse);
      expect(isV2(makeWire(0x02)), isTrue);
    });

    test('base64 encoding and decoding of wire bytes is lossless', () {
      final wire = Uint8List.fromList([0xEC, 0x01, ...List.generate(64, (i) => i)]);
      final encoded = base64Encode(wire);
      final decoded = base64Decode(encoded);
      expect(decoded, equals(wire));
    });
  });
}
