import 'package:echo_app/src/widgets/message/rich_text_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Collect every [TextSpan] (with non-empty text) under [root].
List<TextSpan> _textSpans(InlineSpan root) {
  final out = <TextSpan>[];
  void visit(InlineSpan s) {
    if (s is TextSpan) {
      if ((s.text ?? '').isNotEmpty) out.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  visit(root);
  return out;
}

Future<void> _pump(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RichTextContent(
          text: text,
          textColor: const Color(0xFFEDEDEF),
          accentHoverColor: const Color(0xFF818CF8),
          textSecondaryColor: const Color(0xFFABABB0),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('RichTextContent message-body styling', () {
    // Regression guard for the "spaced-out words" bug: NotoColorEmoji in
    // fontFamilyFallback with NO primary family makes Skia resolve spaces +
    // ASCII punctuation to the emoji font's huge advance widths. Every
    // rendered body span must therefore carry an explicit primary fontFamily
    // (Inter) so the emoji fonts only ever catch real emoji codepoints.
    testWidgets('markdown body spans set an explicit primary font family', (
      tester,
    ) async {
      await _pump(tester, 'normal message, but then **bold**');

      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      expect(richTexts, isNotEmpty);

      var checkedSpans = 0;
      for (final rt in richTexts) {
        for (final span in _textSpans(rt.text)) {
          checkedSpans++;
          expect(
            span.style?.fontFamily,
            isNotNull,
            reason:
                'Body span "${span.text}" must have a primary fontFamily so '
                'the emoji fallback cannot widen spaces/punctuation.',
          );
          expect(
            span.style?.fontFamilyFallback,
            contains('NotoEmoji'),
            reason: 'Emoji fallback should still be present for emoji glyphs.',
          );
        }
      }
      expect(checkedSpans, greaterThan(0));
    });

    testWidgets('punctuation-heavy text still sets a primary font family', (
      tester,
    ) async {
      // The asterisk/punctuation case from the bug report: "* * * * *".
      await _pump(tester, r'* * * * *  @ # $ _ & - + ( ) / ');

      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      for (final rt in richTexts) {
        for (final span in _textSpans(rt.text)) {
          expect(span.style?.fontFamily, isNotNull);
        }
      }
    });
  });
}
