import 'package:echo_app/src/widgets/avatar_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('senderLabelColor (#500)', () {
    // The receive bubble surface uses ~#1F2937 in dark mode.
    const recvSurface = Color(0xFF1F2937);

    test('every palette entry clears WCAG AA 4.5:1 against recv bubble', () {
      // Sample 64 distinct names to exercise the full palette via mod-N.
      for (var i = 0; i < 64; i++) {
        final color = senderLabelColor('user_$i');
        final ratio = _contrastRatio(color, recvSurface);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'senderLabelColor(user_$i) = $color failed contrast on recv bubble',
        );
      }
    });

    test('is deterministic for the same input', () {
      expect(senderLabelColor('alice'), senderLabelColor('alice'));
      expect(senderLabelColor('bob'), senderLabelColor('bob'));
    });
  });
}
