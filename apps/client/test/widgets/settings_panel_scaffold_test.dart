// Regression test for #1169 (and originally #1157): the shared
// SettingsPanelScaffold must catch mouse-wheel events anywhere in the right
// pane, including the side margins outside the centered 900 px content
// column. The whole point of the shared scaffold is that this contract
// lives in one place — if a future refactor breaks it here, every settings
// sub-panel regresses simultaneously, so we lock it down with a focused
// scaffold-only test.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/settings_panel_scaffold.dart';

void main() {
  group('SettingsPanelScaffold', () {
    Future<ScrollPosition> pumpAndFindScroll(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPanelScaffold(
              children: List.generate(
                50,
                (i) =>
                    SizedBox(height: 40, child: Center(child: Text('row $i'))),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final finder = find.byType(Scrollable);
      expect(finder, findsOneWidget);
      return tester.state<ScrollableState>(finder).position;
    }

    Future<void> scrollAt(WidgetTester tester, Offset position) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(position));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await tester.pumpAndSettle();
    }

    testWidgets('right-margin scroll drives the panel (#1157, #1169)', (
      tester,
    ) async {
      final scroll = await pumpAndFindScroll(tester);
      expect(scroll.pixels, 0.0);

      await scrollAt(tester, const Offset(1550, 450));
      expect(scroll.pixels, greaterThan(0.0));
    });

    testWidgets('left-margin scroll drives the panel (#1157, #1169)', (
      tester,
    ) async {
      final scroll = await pumpAndFindScroll(tester);
      expect(scroll.pixels, 0.0);

      await scrollAt(tester, const Offset(50, 450));
      expect(scroll.pixels, greaterThan(0.0));
    });
  });
}
