import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/utils/color_utils.dart';

void main() {
  group('parseHexColor', () {
    test('parses a valid #RRGGBB string to an opaque colour', () {
      expect(parseHexColor('#4F46E5'), const Color(0xFF4F46E5));
      expect(parseHexColor('#000000'), const Color(0xFF000000));
      expect(parseHexColor('#FFFFFF'), const Color(0xFFFFFFFF));
    });

    test('returns null for null / empty', () {
      expect(parseHexColor(null), isNull);
      expect(parseHexColor(''), isNull);
    });

    test('returns null for malformed input instead of throwing', () {
      expect(parseHexColor('4F46E5'), isNull); // missing #
      expect(parseHexColor('#FFF'), isNull); // shorthand, wrong length
      expect(parseHexColor('#GGGGGG'), isNull); // non-hex digits
      expect(parseHexColor('#4F46E5FF'), isNull); // too long
    });
  });
}
