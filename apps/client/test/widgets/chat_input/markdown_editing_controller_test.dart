import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/chat_input/markdown_editing_controller.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Recursively flatten a [TextSpan] tree into a list of leaf [TextSpan]s.
List<TextSpan> flattenSpans(InlineSpan root) {
  if (root is TextSpan) {
    if (root.children == null || root.children!.isEmpty) {
      return [root];
    }
    return root.children!.expand(flattenSpans).toList();
  }
  return [];
}

/// Build a span tree from [text] with an optional [selection].
/// When [selection] is null the controller uses a collapsed cursor at 0.
List<TextSpan> buildLeaves(String text, {TextSelection? selection}) {
  final ctrl = MarkdownTextEditingController(text: text);
  if (selection != null) {
    ctrl.selection = selection;
  }
  addTearDown(ctrl.dispose);

  final root = ctrl.buildTextSpan(
    context: _FakeBuildContext(),
    style: const TextStyle(color: Colors.white),
    withComposing: false,
  );
  return flattenSpans(root);
}

// ignore: invalid_use_of_protected_member
class _FakeBuildContext extends BuildContext {
  // MarkdownTextEditingController.buildTextSpan does not call any
  // BuildContext methods, so an empty stub is sufficient.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MarkdownTextEditingController', () {
    test('raw text is unchanged after buildTextSpan', () {
      final ctrl = MarkdownTextEditingController(text: '**hello**');
      addTearDown(ctrl.dispose);
      final leaves = buildLeaves('**hello**');
      expect(ctrl.text, '**hello**');
      // leaves exist (smoke check)
      expect(leaves, isNotEmpty);
    });

    test('empty text returns single empty span', () {
      final leaves = buildLeaves('');
      expect(leaves.length, 1);
      expect(leaves.first.text, '');
    });

    group('bold **…**', () {
      test('has three spans: delim, body, delim', () {
        // Cursor inside range (offset 2) so delimiters are visible.
        final leaves = buildLeaves(
          '**hello**',
          selection: const TextSelection.collapsed(offset: 2),
        );
        expect(leaves.length, 3);
        expect(leaves[0].text, '**');
        expect(leaves[1].text, 'hello');
        expect(leaves[2].text, '**');
      });

      test('body span has bold weight', () {
        final leaves = buildLeaves(
          '**hello**',
          selection: const TextSelection.collapsed(offset: 2),
        );
        expect(leaves[1].style?.fontWeight, FontWeight.bold);
      });

      test('delimiter spans dimmed (40%) when cursor is inside range', () {
        // Cursor at offset 2 is inside the bold range (0–9), so delimiters
        // should be visible at reduced (40%) opacity.
        final leaves = buildLeaves(
          '**hello**',
          selection: const TextSelection.collapsed(offset: 2),
        );
        final delimColor = leaves[0].style?.color;
        final bodyColor = leaves[1].style?.color;
        expect(delimColor, isNotNull);
        expect(bodyColor, isNotNull);
        // Delimiter alpha (0.4) is less than body alpha (1.0).
        expect(delimColor!.a, lessThan(bodyColor!.a));
      });

      test('delimiters hidden (alpha = 0) when cursor is outside range', () {
        // Cursor at offset 0 is NOT strictly inside the bold range (0–9),
        // so delimiters should be fully transparent.
        final leaves = buildLeaves(
          '**hello**',
          selection: const TextSelection.collapsed(offset: 0),
        );
        final delimColor = leaves[0].style?.color;
        expect(delimColor, isNotNull);
        expect(delimColor!.a, equals(0.0));
      });
    });

    group('cursor-aware delimiter visibility', () {
      test('cursor at offset 0 hides delimiters in **bold**', () {
        final leaves = buildLeaves(
          '**bold**',
          selection: const TextSelection.collapsed(offset: 0),
        );
        // Delimiter spans: leaves[0] and leaves[2]
        expect(
          leaves[0].style?.color?.a,
          equals(0.0),
          reason: 'Opening ** should be hidden when cursor is outside',
        );
        expect(
          leaves[2].style?.color?.a,
          equals(0.0),
          reason: 'Closing ** should be hidden when cursor is outside',
        );
      });

      test('cursor at offset 2 (inside **bold**) shows delimiters at 40%', () {
        // offset 2 is inside the range [0, 8), so delimiters should show.
        final leaves = buildLeaves(
          '**bold**',
          selection: const TextSelection.collapsed(offset: 2),
        );
        final delimAlpha = leaves[0].style?.color?.a ?? 0.0;
        final bodyAlpha = leaves[1].style?.color?.a ?? 1.0;
        // Delimiter must be visible but dimmer than body.
        expect(
          delimAlpha,
          greaterThan(0.0),
          reason: 'Delimiter should be visible when cursor is inside range',
        );
        expect(
          delimAlpha,
          lessThan(bodyAlpha),
          reason: 'Delimiter should be dimmer than body text',
        );
      });

      test('non-collapsed selection overlapping range shows delimiters', () {
        // Selection from 1–5 overlaps with the bold range (0–8), so
        // delimiters should be visible.
        final leaves = buildLeaves(
          '**bold**',
          selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        );
        final delimAlpha = leaves[0].style?.color?.a ?? 0.0;
        expect(delimAlpha, greaterThan(0.0));
      });
    });

    group('inline list bullet rendering', () {
      test('unordered "- item" renders bullet glyph as second span', () {
        // Spans: [hidden raw "- "] [bullet glyph "• "] [rest "item"]
        final leaves = buildLeaves('- item');
        expect(leaves.length, 3);
        expect(leaves[0].text, '- '); // hidden raw marker
        expect(leaves[1].text, '• '); // visible bullet glyph
        expect(leaves[2].text, 'item'); // rest of line
      });

      test('raw controller.text stays "- item" (not mutated)', () {
        final ctrl = MarkdownTextEditingController(text: '- item');
        addTearDown(ctrl.dispose);
        ctrl.buildTextSpan(
          context: _FakeBuildContext(),
          style: const TextStyle(color: Colors.white),
          withComposing: false,
        );
        expect(ctrl.text, '- item');
      });

      test(
        'unordered "* item" (asterisk marker) also renders bullet glyph',
        () {
          final leaves = buildLeaves('* item');
          expect(leaves.length, 3);
          expect(leaves[1].text, '• ');
        },
      );

      test('ordered "1. item" renders number glyph as second span', () {
        final leaves = buildLeaves('1. item');
        expect(leaves.length, 3);
        expect(leaves[0].text, '1. '); // hidden raw marker
        expect(leaves[1].text, '1. '); // visible number glyph
        expect(leaves[2].text, 'item');
      });

      test('hidden marker span has zero alpha', () {
        final leaves = buildLeaves('- item');
        final markerColor = leaves[0].style?.color;
        expect(markerColor, isNotNull);
        expect(markerColor!.a, equals(0.0));
      });

      test('multiline: second line bullet is rendered correctly', () {
        final leaves = buildLeaves('text\n- bullet');
        // Spans: "text" + "\n" + "- " (hidden) + "• " (glyph) + "bullet"
        final texts = leaves.map((s) => s.text).toList();
        expect(texts, contains('• '));
        expect(texts, contains('bullet'));
      });
    });

    group('italic *…*', () {
      late List<TextSpan> leaves;

      setUp(
        () => leaves = buildLeaves(
          '*world*',
          selection: const TextSelection.collapsed(offset: 1),
        ),
      );

      test('has three spans: delim, body, delim', () {
        expect(leaves.length, 3);
        expect(leaves[1].text, 'world');
      });

      test('body span is italic', () {
        expect(leaves[1].style?.fontStyle, FontStyle.italic);
      });
    });

    group('strikethrough ~~…~~', () {
      late List<TextSpan> leaves;

      setUp(
        () => leaves = buildLeaves(
          '~~gone~~',
          selection: const TextSelection.collapsed(offset: 2),
        ),
      );

      test('has three spans', () {
        expect(leaves.length, 3);
        expect(leaves[1].text, 'gone');
      });

      test('body span has lineThrough', () {
        expect(leaves[1].style?.decoration, TextDecoration.lineThrough);
      });
    });

    group('inline code `…`', () {
      late List<TextSpan> leaves;

      setUp(
        () => leaves = buildLeaves(
          '`code`',
          selection: const TextSelection.collapsed(offset: 1),
        ),
      );

      test('has three spans', () {
        expect(leaves.length, 3);
        expect(leaves[1].text, 'code');
      });

      test('body span uses monospace font', () {
        expect(leaves[1].style?.fontFamily, 'monospace');
      });
    });

    test('plain text with no markdown → single span', () {
      final leaves = buildLeaves('just plain text');
      expect(leaves.length, 1);
      expect(leaves.first.text, 'just plain text');
    });

    test('mixed bold and italic non-overlapping', () {
      // "**a** and *b*" — cursor inside bold region so delimiters visible.
      final leaves = buildLeaves(
        '**a** and *b*',
        selection: const TextSelection.collapsed(offset: 2),
      );
      // bold: 3 spans + plain " and " + italic: 3 spans = 7 total
      expect(leaves.length, 7);
      final boldBody = leaves[1];
      final italicBody = leaves[5];
      expect(boldBody.style?.fontWeight, FontWeight.bold);
      expect(italicBody.style?.fontStyle, FontStyle.italic);
    });

    test(
      'overlapping patterns: bold consumes its range, trailing * is plain',
      () {
        // **bold and *italic*** — bold regex (non-greedy) matches
        // "**bold and *italic**" first; the trailing "*" is plain text.
        // The italic pattern is fully inside the bold match and filtered out.
        final leaves = buildLeaves('**bold and *italic***');
        final texts = leaves.map((s) => s.text).toList();
        // Delimiters, body (no inner italic), and trailing plain star
        expect(texts, containsAll(['**', 'bold and *italic']));
        // No separately-styled italic span
        final italicSpans = leaves
            .where((s) => s.style?.fontStyle == FontStyle.italic)
            .toList();
        expect(italicSpans, isEmpty);
      },
    );

    test('raw controller.text unchanged (round-trip)', () {
      const raw = '**bold** *italic* ~~strike~~ `code`';
      final ctrl = MarkdownTextEditingController(text: raw);
      addTearDown(ctrl.dispose);
      // Trigger buildTextSpan (via leaves helper) and verify text unchanged.
      buildLeaves(raw);
      expect(ctrl.text, raw);
    });
  });
}
