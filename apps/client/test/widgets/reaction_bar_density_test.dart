import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/providers/theme_provider.dart' show UIDensity;
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/message/reaction_bar.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: EchoTheme.darkTheme,
    darkTheme: EchoTheme.darkTheme,
    themeMode: ThemeMode.dark,
    home: Scaffold(body: child),
  );
}

const _reactions = [
  Reaction(messageId: 'm1', userId: 'u1', username: 'alice', emoji: '🎉'),
];

Future<void> _pumpAt(WidgetTester tester, UIDensity density) async {
  await tester.pumpWidget(
    _wrap(
      ReactionBar(
        reactions: _reactions,
        currentUserId: 'me',
        isMine: false,
        chatBgColor: Colors.black,
        density: density,
      ),
    ),
  );
  // Settle the entry animation so the pill renders at full size.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('ReactionBar density', () {
    testWidgets('cozy renders 15pt emoji and 13pt count', (tester) async {
      await _pumpAt(tester, UIDensity.cozy);
      final emoji = tester.widget<Text>(find.text('🎉'));
      final count = tester.widget<Text>(find.text('1'));
      expect(emoji.style?.fontSize, 15);
      expect(count.style?.fontSize, 13);
    });

    testWidgets('normal renders 14pt emoji and 12pt count', (tester) async {
      await _pumpAt(tester, UIDensity.normal);
      final emoji = tester.widget<Text>(find.text('🎉'));
      final count = tester.widget<Text>(find.text('1'));
      expect(emoji.style?.fontSize, 14);
      expect(count.style?.fontSize, 12);
    });

    testWidgets('compact renders 13pt emoji and 11pt count (today\'s)', (
      tester,
    ) async {
      await _pumpAt(tester, UIDensity.compact);
      final emoji = tester.widget<Text>(find.text('🎉'));
      final count = tester.widget<Text>(find.text('1'));
      expect(emoji.style?.fontSize, 13);
      expect(count.style?.fontSize, 11);
    });

    testWidgets('default density (no param) is compact for back-compat', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ReactionBar(
            reactions: _reactions,
            currentUserId: 'me',
            isMine: false,
            chatBgColor: Colors.black,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final emoji = tester.widget<Text>(find.text('🎉'));
      expect(emoji.style?.fontSize, 13);
    });
  });
}
