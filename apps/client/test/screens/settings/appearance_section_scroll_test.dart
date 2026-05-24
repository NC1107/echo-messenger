// Regression test for #1157: scroll-wheel events in the side margins of the
// Appearance settings pane must drive the panel's scroll. Previously the pane
// nested a max-900px ListView inside Center + ConstrainedBox, so anything
// outside the 900 px content column received no scroll surface and the wheel
// did nothing.
//
// Pump the section in a 1600 px window, fire a PointerScrollEvent 50 px from
// the right edge (guaranteed to be outside the 900 px column), and assert the
// SingleChildScrollView's offset increased.

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

  testWidgets('side-margin scroll drives the appearance panel (#1157)', (
    tester,
  ) async {
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

    final scrollableFinder = find.byType(Scrollable);
    expect(scrollableFinder, findsOneWidget);
    final scrollPosition = tester
        .state<ScrollableState>(scrollableFinder)
        .position;
    expect(scrollPosition.pixels, 0.0);

    // Pointer 50 px from the right edge — well outside the 900 px content
    // column on a 1600 px window. Before the fix this position received no
    // scroll surface and the event did nothing.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    const sidePosition = Offset(1550, 450);
    await tester.sendEventToBinding(pointer.hover(sidePosition));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();

    expect(
      scrollPosition.pixels,
      greaterThan(0.0),
      reason:
          'Scrolling at the right margin (1550 px on a 1600 px window) must '
          'drive the Appearance panel — fix for #1157.',
    );
  });
}
