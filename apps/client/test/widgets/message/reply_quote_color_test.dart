import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/message/reply_quote.dart';

/// Pumps [widget] in a MaterialApp using [themeData].
Future<void> _pumpWithTheme(
  WidgetTester tester,
  Widget widget,
  ThemeData themeData,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: themeData,
        darkTheme: themeData,
        themeMode: ThemeMode.dark,
        home: Scaffold(body: widget),
      ),
    ),
  );
}

/// Returns the [Container] decoration for the reply-quote overlay (the inner
/// translucent box that appears on sent-bubble replies).
BoxDecoration _replyQuoteDecoration(WidgetTester tester) {
  // The overlay Container is the first Container inside ReplyQuote.
  final containers = tester.widgetList<Container>(
    find.descendant(
      of: find.byType(ReplyQuote),
      matching: find.byType(Container),
    ),
  );
  return containers.first.decoration! as BoxDecoration;
}

void main() {
  group('ReplyQuote -- _buildColorOverlays uses bubble-bg luminance', () {
    // The overlay alpha and border alpha should be driven by the SENT-BUBBLE
    // BACKGROUND luminance, not by onSentBubble luminance.
    //
    // Themes with a light/high-luminance sent bubble (Ember amber, Graphite
    // teal) should use the lower-alpha path (0.12 / 0.50).
    // Themes with a dark sent bubble (indigo, paper, sakura) should use the
    // higher-alpha path (0.18 / 0.55).

    testWidgets(
      'Ember theme: overlay uses lower alpha on high-luminance amber bubble',
      (tester) async {
        const quote = ReplyQuote(
          replyToUsername: 'alice',
          replyToContent: 'Hey there!',
          isMine: true,
        );
        await _pumpWithTheme(tester, quote, EchoTheme.emberTheme);
        await tester.pump();

        final deco = _replyQuoteDecoration(tester);
        // Color.a returns 0.0–1.0. Low-alpha path = 0.12, high-alpha = 0.18.
        final overlayAlpha = deco.color!.a;

        // Ember sent bubble is amber (luminance ~0.39, > 0.3 → "not dark").
        // Expect lower overlay alpha (0.12 path).
        expect(
          overlayAlpha,
          lessThan(0.15),
          reason:
              'Ember (light amber bubble) should use the low-alpha (0.12) overlay',
        );
      },
    );

    testWidgets('Dark-indigo theme: overlay uses higher alpha on dark bubble', (
      tester,
    ) async {
      const quote = ReplyQuote(
        replyToUsername: 'alice',
        replyToContent: 'Hey there!',
        isMine: true,
      );
      await _pumpWithTheme(tester, quote, EchoTheme.darkTheme);
      await tester.pump();

      final deco = _replyQuoteDecoration(tester);
      // Color.a returns 0.0–1.0. Low-alpha path = 0.12, high-alpha = 0.18.
      final overlayAlpha = deco.color!.a;

      // Dark indigo sent bubble (luminance ~0.14 < 0.3 → "dark bubble").
      // Expect higher overlay alpha (0.18 path).
      expect(
        overlayAlpha,
        greaterThan(0.15),
        reason:
            'Dark theme (dark indigo bubble) should use the high-alpha (0.18) overlay',
      );
    });

    testWidgets('Received-bubble (isMine: false) is unaffected by the change', (
      tester,
    ) async {
      // Non-mine bubbles use context.accent + fixed alpha — not the sentBubble
      // path at all. Verify the widget renders without error.
      const quote = ReplyQuote(
        replyToUsername: 'bob',
        replyToContent: 'Hey there!',
        isMine: false,
      );
      await _pumpWithTheme(tester, quote, EchoTheme.emberTheme);
      await tester.pump();

      expect(find.text('bob'), findsOneWidget);
      expect(find.text('Hey there!'), findsOneWidget);
    });

    testWidgets('Ember sent-bubble reply renders username text without error', (
      tester,
    ) async {
      const quote = ReplyQuote(
        replyToUsername: 'alice',
        replyToContent: 'Some message body',
        isMine: true,
      );
      await _pumpWithTheme(tester, quote, EchoTheme.emberTheme);
      await tester.pump();

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Some message body'), findsOneWidget);
    });

    testWidgets(
      'Light/paper theme: overlay uses higher alpha on dark sent-bubble',
      (tester) async {
        const quote = ReplyQuote(
          replyToUsername: 'alice',
          replyToContent: 'Hey there!',
          isMine: true,
        );
        await _pumpWithTheme(tester, quote, EchoTheme.lightTheme);
        await tester.pump();

        final deco = _replyQuoteDecoration(tester);
        final overlayAlpha = deco.color!.a;

        // Paper sent bubble is deep indigo (luminance ~0.12 < 0.3 → "dark").
        // Expect higher overlay alpha (0.18 path). Color.a is 0.0–1.0.
        expect(
          overlayAlpha,
          greaterThan(0.15),
          reason:
              'Light/paper theme (dark indigo bubble) should use high-alpha overlay',
        );
      },
    );
  });
}
