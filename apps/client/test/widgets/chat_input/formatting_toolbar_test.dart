import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/chat_input/formatting_toolbar.dart';
import 'package:echo_app/src/widgets/chat_input/markdown_editing_controller.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pumps an [AaToggleButton] + [FormattingToolbar] combo in a minimal app
/// and returns the [MarkdownTextEditingController] and
/// [AnimationController] for direct inspection.
Future<({MarkdownTextEditingController ctrl, AnimationController anim})>
pumpToolbar(WidgetTester tester, {String initialText = ''}) async {
  final ctrl = MarkdownTextEditingController(text: initialText);
  final animCtrl = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 150),
  );
  // Start the animation as forward (toolbar visible) so buttons are hittable.
  animCtrl.value = 1.0;

  addTearDown(() {
    ctrl.dispose();
    animCtrl.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormattingToolbar(
          controller: ctrl,
          animationController: animCtrl,
        ),
      ),
    ),
  );
  await tester.pump();

  return (ctrl: ctrl, anim: animCtrl);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FormattingToolbar', () {
    testWidgets('renders four icon buttons', (tester) async {
      await pumpToolbar(tester);
      expect(find.byType(IconButton), findsNWidgets(4));
    });

    group('Bold button', () {
      testWidgets(
        'no selection on empty text → inserts **** with cursor inside',
        (tester) async {
          final result = await pumpToolbar(tester);
          final ctrl = result.ctrl;

          // Collapsed cursor at position 0
          ctrl.selection = const TextSelection.collapsed(offset: 0);

          await tester.tap(find.byIcon(Icons.format_bold));
          await tester.pump();

          expect(ctrl.text, '****');
          expect(ctrl.selection.baseOffset, 2);
        },
      );

      testWidgets('selection "hello" → wraps to **hello**', (tester) async {
        final result = await pumpToolbar(tester, initialText: 'hello');
        final ctrl = result.ctrl;

        ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 5);

        await tester.tap(find.byIcon(Icons.format_bold));
        await tester.pump();

        expect(ctrl.text, '**hello**');
      });
    });

    group('Italic button', () {
      testWidgets('no selection → inserts ** with cursor inside', (
        tester,
      ) async {
        final result = await pumpToolbar(tester);
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection.collapsed(offset: 0);

        await tester.tap(find.byIcon(Icons.format_italic));
        await tester.pump();

        expect(ctrl.text, '**');
        expect(ctrl.selection.baseOffset, 1);
      });

      testWidgets('selection → wraps with *', (tester) async {
        final result = await pumpToolbar(tester, initialText: 'hi');
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);

        await tester.tap(find.byIcon(Icons.format_italic));
        await tester.pump();

        expect(ctrl.text, '*hi*');
      });
    });

    group('Strikethrough button', () {
      testWidgets('selection → wraps with ~~', (tester) async {
        final result = await pumpToolbar(tester, initialText: 'out');
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 3);

        await tester.tap(find.byIcon(Icons.format_strikethrough));
        await tester.pump();

        expect(ctrl.text, '~~out~~');
      });

      testWidgets('no selection → inserts ~~~~ cursor inside', (tester) async {
        final result = await pumpToolbar(tester);
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection.collapsed(offset: 0);

        await tester.tap(find.byIcon(Icons.format_strikethrough));
        await tester.pump();

        expect(ctrl.text, '~~~~');
        expect(ctrl.selection.baseOffset, 2);
      });
    });

    group('Inline code button', () {
      testWidgets('selection → wraps with backticks', (tester) async {
        final result = await pumpToolbar(tester, initialText: 'fn()');
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 4);

        await tester.tap(find.byIcon(Icons.code));
        await tester.pump();

        expect(ctrl.text, '`fn()`');
      });

      testWidgets('no selection → inserts `` cursor inside', (tester) async {
        final result = await pumpToolbar(tester);
        final ctrl = result.ctrl;
        ctrl.selection = const TextSelection.collapsed(offset: 0);

        await tester.tap(find.byIcon(Icons.code));
        await tester.pump();

        expect(ctrl.text, '``');
        expect(ctrl.selection.baseOffset, 1);
      });
    });
  });

  group('AaToggleButton', () {
    testWidgets('calls onToggle when tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AaToggleButton(active: false, onToggle: () => tapped = true),
          ),
        ),
      );

      await tester.tap(find.byType(IconButton));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });
}
