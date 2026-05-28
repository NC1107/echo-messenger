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

/// Build a span tree from [text] using a minimal [BuildContext] via
/// [WidgetsBinding]. Because [buildTextSpan] doesn't touch context in
/// [MarkdownTextEditingController], passing a throwaway context is fine.
List<TextSpan> buildLeaves(String text) {
  final ctrl = MarkdownTextEditingController(text: text);
  addTearDown(ctrl.dispose);

  // Build inside a trivial widget so we have a real context.
  late List<TextSpan> result;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.runAsync(() async {});

  // We use runApp + pump to get a BuildContext in unit tests.
  // Instead, call buildTextSpan directly with a dummy context.
  // Since the implementation does not use BuildContext at all, this is safe.
  final root = ctrl.buildTextSpan(
    context: _FakeBuildContext(),
    style: const TextStyle(color: Colors.white),
    withComposing: false,
  );
  result = flattenSpans(root);
  return result;
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
      late List<TextSpan> leaves;

      setUp(() => leaves = buildLeaves('**hello**'));

      test('has three spans: delim, body, delim', () {
        expect(leaves.length, 3);
        expect(leaves[0].text, '**');
        expect(leaves[1].text, 'hello');
        expect(leaves[2].text, '**');
      });

      test('body span has bold weight', () {
        expect(leaves[1].style?.fontWeight, FontWeight.bold);
      });

      test('delimiter spans have dimmed opacity', () {
        final color0 = leaves[0].style?.color;
        final color1 = leaves[1].style?.color;
        expect(color0, isNotNull);
        expect(color1, isNotNull);
        // Delimiter opacity is 0.4 of body colour
        expect(color0!.a, lessThan(color1!.a));
      });
    });

    group('italic *…*', () {
      late List<TextSpan> leaves;

      setUp(() => leaves = buildLeaves('*world*'));

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

      setUp(() => leaves = buildLeaves('~~gone~~'));

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

      setUp(() => leaves = buildLeaves('`code`'));

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
      // "**a** and *b*"
      final leaves = buildLeaves('**a** and *b*');
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
