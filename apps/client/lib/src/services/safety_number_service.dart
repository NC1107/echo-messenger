/// Safety number generation for key verification between two peers.
///
/// Produces a deterministic 60-digit safety number from two identity public
/// keys. Both parties compute the same number regardless of who initiates,
/// because the keys are sorted before hashing.
///
/// Follows a similar approach to Signal's safety numbers: each key contributes
/// 30 digits derived from SHA-512 hashes, giving a collision-resistant
/// fingerprint that users can compare out-of-band.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SafetyNumberService {
  static final _sha512 = Sha512();

  /// Generate a 60-digit safety number from two identity public keys.
  ///
  /// Each key produces 30 digits. The lexicographically lower key always
  /// comes first so both parties compute the same number.
  static Future<String> generate(
    Uint8List myIdentityKey,
    Uint8List peerIdentityKey,
  ) async {
    // Sort keys so both parties compute the same number.
    final comparison = _compareBytes(myIdentityKey, peerIdentityKey);
    final first = comparison < 0 ? myIdentityKey : peerIdentityKey;
    final second = comparison < 0 ? peerIdentityKey : myIdentityKey;

    // Hash each key with SHA-512 using both keys as context.
    // hash1 = SHA-512(first || second || first)
    // hash2 = SHA-512(second || first || second)
    final input1 = Uint8List(first.length + second.length + first.length);
    input1.setRange(0, first.length, first);
    input1.setRange(first.length, first.length + second.length, second);
    input1.setRange(first.length + second.length, input1.length, first);

    final input2 = Uint8List(second.length + first.length + second.length);
    input2.setRange(0, second.length, second);
    input2.setRange(second.length, second.length + first.length, first);
    input2.setRange(second.length + first.length, input2.length, second);

    final hash1 = await _sha512.hash(input1);
    final hash2 = await _sha512.hash(input2);

    final digits1 = _bytesToDigits(Uint8List.fromList(hash1.bytes), 30);
    final digits2 = _bytesToDigits(Uint8List.fromList(hash2.bytes), 30);

    return digits1 + digits2;
  }

  /// Format a 60-digit safety number as groups of 5 for readability.
  ///
  /// Example: "12345 67890 12345 67890 ..."
  static String formatForDisplay(String safetyNumber) {
    final buffer = StringBuffer();
    for (var i = 0; i < safetyNumber.length; i += 5) {
      if (i > 0) buffer.write(' ');
      buffer.write(safetyNumber.substring(i, min(i + 5, safetyNumber.length)));
    }
    return buffer.toString();
  }

  /// Convert the first [digitCount] digits from hash bytes.
  ///
  /// Each byte mod 100 produces 2 digits. We take [digitCount / 2] bytes
  /// and convert each to a zero-padded 2-digit decimal string.
  static String _bytesToDigits(Uint8List hashBytes, int digitCount) {
    final buffer = StringBuffer();
    final bytesNeeded = digitCount ~/ 2;
    for (var i = 0; i < bytesNeeded && i < hashBytes.length; i++) {
      buffer.write((hashBytes[i] % 100).toString().padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Lexicographic byte comparison.
  static int _compareBytes(Uint8List a, Uint8List b) {
    final len = min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
