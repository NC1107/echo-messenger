// Widget tests for ScrollToBottomButton — visibility driven by [visible] flag.
//
// ScrollToBottomButton contains a Positioned widget, so every test wraps it
// in a Stack (matching the production placement inside _buildMessageListStack).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/chat_panel/scroll_to_bottom_button.dart';

import '../../helpers/pump_app.dart';

/// Pumps a Stack containing [ScrollToBottomButton] with [visible].
Future<void> _pump(
  WidgetTester tester, {
  required bool visible,
  VoidCallback? onTap,
}) async {
  await tester.pumpApp(
    Stack(
      children: [ScrollToBottomButton(visible: visible, onTap: onTap ?? () {})],
    ),
  );
}

/// Returns the first FadeTransition that is a descendant of ScrollToBottomButton.
FadeTransition _buttonFade(WidgetTester tester) => tester
    .widgetList<FadeTransition>(
      find.descendant(
        of: find.byType(ScrollToBottomButton),
        matching: find.byType(FadeTransition),
      ),
    )
    .first;

void main() {
  group('ScrollToBottomButton', () {
    testWidgets('is hidden (opacity 0) when visible is false', (tester) async {
      await _pump(tester, visible: false);
      // Animation has not been forwarded — opacity should be 0.
      expect(_buttonFade(tester).opacity.value, closeTo(0.0, 0.01));
    });

    testWidgets('appears (opacity 1) when visible becomes true', (
      tester,
    ) async {
      bool isVisible = false;

      await tester.pumpApp(
        StatefulBuilder(
          builder: (context, setState) {
            return Stack(
              children: [
                ScrollToBottomButton(visible: isVisible, onTap: () {}),
                Positioned(
                  bottom: 120,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ElevatedButton(
                      onPressed: () => setState(() => isVisible = true),
                      child: const Text('show'),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

      // Initially hidden.
      expect(_buttonFade(tester).opacity.value, closeTo(0.0, 0.01));

      // Toggle visible = true and let the 200 ms animation settle.
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();

      expect(_buttonFade(tester).opacity.value, closeTo(1.0, 0.01));
    });

    testWidgets('hides again (opacity 0) when visible goes back to false', (
      tester,
    ) async {
      bool isVisible = true;

      await tester.pumpApp(
        StatefulBuilder(
          builder: (context, setState) {
            return Stack(
              children: [
                ScrollToBottomButton(visible: isVisible, onTap: () {}),
                Positioned(
                  bottom: 120,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ElevatedButton(
                      onPressed: () => setState(() => isVisible = false),
                      child: const Text('hide'),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

      // Let the entrance animation finish.
      await tester.pumpAndSettle();
      expect(_buttonFade(tester).opacity.value, closeTo(1.0, 0.01));

      // Toggle visible = false and let the exit animation finish.
      await tester.tap(find.text('hide'));
      await tester.pumpAndSettle();

      expect(_buttonFade(tester).opacity.value, closeTo(0.0, 0.01));
    });

    testWidgets('carries the a11y label "Jump to latest messages"', (
      tester,
    ) async {
      await _pump(tester, visible: true);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Jump to latest messages'), findsOneWidget);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      int taps = 0;
      await _pump(tester, visible: true, onTap: () => taps++);
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(ScrollToBottomButton),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(taps, 1);
    });
  });
}
