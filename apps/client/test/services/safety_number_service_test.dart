import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/safety_number_service.dart';

void main() {
  group('SafetyNumberService', () {
    group('generate', () {
      test('produces a 60-digit string', () async {
        final keyA = Uint8List.fromList(List.generate(32, (i) => i));
        final keyB = Uint8List.fromList(List.generate(32, (i) => i + 100));

        final result = await SafetyNumberService.generate(keyA, keyB);

        expect(result.length, 60);
        expect(RegExp(r'^\d{60}$').hasMatch(result), isTrue);
      });

      test('is deterministic for the same key pair', () async {
        final keyA = Uint8List.fromList(List.generate(32, (i) => i));
        final keyB = Uint8List.fromList(List.generate(32, (i) => i + 50));

        final result1 = await SafetyNumberService.generate(keyA, keyB);
        final result2 = await SafetyNumberService.generate(keyA, keyB);

        expect(result1, equals(result2));
      });

      test('is commutative -- both parties get the same number', () async {
        final keyA = Uint8List.fromList(List.generate(32, (i) => i));
        final keyB = Uint8List.fromList(List.generate(32, (i) => 255 - i));

        final fromAlice = await SafetyNumberService.generate(keyA, keyB);
        final fromBob = await SafetyNumberService.generate(keyB, keyA);

        expect(fromAlice, equals(fromBob));
      });

      test('different key pairs produce different numbers', () async {
        final keyA = Uint8List.fromList(List.generate(32, (i) => i));
        final keyB = Uint8List.fromList(List.generate(32, (i) => i + 100));
        final keyC = Uint8List.fromList(List.generate(32, (i) => i + 200));

        final resultAB = await SafetyNumberService.generate(keyA, keyB);
        final resultAC = await SafetyNumberService.generate(keyA, keyC);

        expect(resultAB, isNot(equals(resultAC)));
      });

      test('handles identical keys', () async {
        final key = Uint8List.fromList(List.generate(32, (i) => i));

        final result = await SafetyNumberService.generate(key, key);

        expect(result.length, 60);
        expect(RegExp(r'^\d{60}$').hasMatch(result), isTrue);
      });
    });

    group('formatForDisplay', () {
      test('groups digits into blocks of 5', () {
        final number = '1' * 60;
        final formatted = SafetyNumberService.formatForDisplay(number);

        final groups = formatted.split(' ');
        expect(groups.length, 12);
        for (final group in groups) {
          expect(group.length, 5);
        }
      });

      test('handles non-multiple-of-5 lengths gracefully', () {
        final formatted = SafetyNumberService.formatForDisplay('1234567');
        expect(formatted, '12345 67');
      });

      test('handles empty string', () {
        final formatted = SafetyNumberService.formatForDisplay('');
        expect(formatted, '');
      });

      test('single group has no leading space', () {
        final formatted = SafetyNumberService.formatForDisplay('12345');
        expect(formatted, '12345');
      });
    });
  });
}
