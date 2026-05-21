import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/utils/presence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('presenceColor', () {
    test('online: known statuses map to themed colours', () {
      expect(presenceColor('online'), EchoTheme.online);
      expect(presenceColor('away'), EchoTheme.warning);
      expect(presenceColor('dnd'), EchoTheme.danger);
    });

    test('"invisible" looks the same as offline to peers', () {
      expect(
        presenceColor('invisible'),
        presenceColor('online', isOnline: false),
      );
    });

    test('isOnline=false overrides any status', () {
      expect(presenceColor('online', isOnline: false), const Color(0xFF6B6B6F));
      expect(presenceColor('away', isOnline: false), const Color(0xFF6B6B6F));
    });

    test('unknown status falls back to offline grey, not online green', () {
      expect(presenceColor('quantum'), const Color(0xFF6B6B6F));
    });
  });

  group('presenceLabel', () {
    test('isOnline=false collapses every status to offline', () {
      expect(presenceLabel('online', isOnline: false), 'offline');
      expect(presenceLabel('away', isOnline: false), 'offline');
      expect(presenceLabel('dnd', isOnline: false), 'offline');
    });

    test('"invisible" reads as offline even when online flag is true', () {
      expect(presenceLabel('invisible', isOnline: true), 'offline');
    });

    test('"dnd" is spelled out for screen readers', () {
      expect(presenceLabel('dnd'), 'do not disturb');
    });

    test('away keeps its short form', () {
      expect(presenceLabel('away'), 'away');
    });
  });
}
