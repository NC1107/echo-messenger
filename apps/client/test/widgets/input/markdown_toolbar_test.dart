import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/input/markdown_toolbar.dart';

void main() {
  group('applyMarkdownWrap', () {
    late TextEditingController ctrl;

    setUp(() => ctrl = TextEditingController());
    tearDown(() => ctrl.dispose());

    test('selection 5..10 bold → wraps selected word, cursor after suffix', () {
      // "beforefiveafter" — select indices 6..10 ("five")
      const text = 'beforefiveafter';
      ctrl.value = const TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 6, extentOffset: 10),
      );

      applyMarkdownWrap(ctrl, prefix: '**', suffix: '**');

      expect(ctrl.text, 'before**five**after');
      // Cursor should be after the closing **
      expect(ctrl.selection.baseOffset, 'before**five**'.length);
    });

    test('empty selection italic → inserts markers, cursor between them', () {
      ctrl.value = const TextEditingValue(
        text: 'hello ',
        selection: TextSelection.collapsed(offset: 6),
      );

      applyMarkdownWrap(ctrl, prefix: '*', suffix: '*');

      expect(ctrl.text, 'hello **');
      // Cursor is between the two asterisks
      expect(ctrl.selection.baseOffset, 7);
    });

    test('selection with bold → correct text', () {
      ctrl.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );

      applyMarkdownWrap(ctrl, prefix: '**', suffix: '**');

      expect(ctrl.text, 'hello **world**');
    });

    test('empty selection code → inserts backticks, cursor between', () {
      ctrl.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );

      applyMarkdownWrap(ctrl, prefix: '`', suffix: '`');

      expect(ctrl.text, '``');
      expect(ctrl.selection.baseOffset, 1);
    });

    test('selection strikethrough → wraps with ~~', () {
      ctrl.value = const TextEditingValue(
        text: 'remove this text',
        selection: TextSelection(baseOffset: 7, extentOffset: 11),
      );

      applyMarkdownWrap(ctrl, prefix: '~~', suffix: '~~');

      expect(ctrl.text, 'remove ~~this~~ text');
    });
  });

  group('applyQuotePrefix', () {
    late TextEditingController ctrl;

    setUp(() => ctrl = TextEditingController());
    tearDown(() => ctrl.dispose());

    test('single line → prefixes with "> "', () {
      ctrl.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection(baseOffset: 0, extentOffset: 5),
      );

      applyQuotePrefix(ctrl);

      expect(ctrl.text, '> hello');
    });

    test('multi-line selection → prefixes each line', () {
      ctrl.value = const TextEditingValue(
        text: 'line one\nline two',
        selection: TextSelection(baseOffset: 0, extentOffset: 17),
      );

      applyQuotePrefix(ctrl);

      expect(ctrl.text, '> line one\n> line two');
    });
  });

  group('MarkdownToolbar widget', () {
    testWidgets('renders 6 icon buttons', (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownToolbar(controller: ctrl)),
        ),
      );

      expect(find.byType(IconButton), findsNWidgets(6));
    });

    testWidgets('bold button wraps selected text', (tester) async {
      final ctrl = TextEditingController(text: 'hello world');
      ctrl.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownToolbar(controller: ctrl)),
        ),
      );

      // Tap the bold button (first icon button)
      await tester.tap(find.byIcon(Icons.format_bold));
      await tester.pump();

      expect(ctrl.text, 'hello **world**');
    });
  });
}
