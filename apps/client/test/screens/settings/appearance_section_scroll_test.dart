// Regression test for #1157: scroll-wheel events in the side margins of the
// Appearance settings pane must drive the panel's scroll. Previously the pane
// nested a max-900px ListView inside Center + ConstrainedBox, so anything
// outside the 900 px content column received no scroll surface and the wheel
// did nothing.
//
// On a 1600 px window the centered 900 px column sits at x≈350..1250, so
// fire a PointerScrollEvent at x=1550 (right margin) AND x=50 (left margin),
// asserting both drive the scroll — symmetric coverage so a future regression
// that only re-narrows one side still fails.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/appearance_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ScrollPosition> pumpAndFindScroll(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          home: const Scaffold(body: AppearanceSection()),
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

  testWidgets('right-margin scroll drives the appearance panel (#1157)', (
    tester,
  ) async {
    final scroll = await pumpAndFindScroll(tester);
    expect(scroll.pixels, 0.0);

    await scrollAt(tester, const Offset(1550, 450));
    expect(scroll.pixels, greaterThan(0.0));
  });

  testWidgets('left-margin scroll drives the appearance panel (#1157)', (
    tester,
  ) async {
    final scroll = await pumpAndFindScroll(tester);
    expect(scroll.pixels, 0.0);

    await scrollAt(tester, const Offset(50, 450));
    expect(scroll.pixels, greaterThan(0.0));
  });
}
