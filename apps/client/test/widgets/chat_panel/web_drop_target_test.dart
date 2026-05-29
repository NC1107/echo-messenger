// Drag-and-drop is implemented via `package:desktop_drop` (`DropTarget`) and
// the `DropOverlay` widget; actual HTML drag events cannot be simulated in
// `flutter test` because the DOM is not available outside a browser host.
//
// These tests cover:
//   - `DropOverlay` hidden (opacity 0) when `isDragOver` is false — the idle
//     state on every platform including web.
//   - `DropOverlay` visible (opacity 1) when `isDragOver` is true — the
//     "dragging over chat" feedback state.
//
// End-to-end browser verification (real file drag into the chat area on web)
// is tracked as a follow-up Playwright spec: tests/e2e/chat_drag_drop.spec.ts.
//
// NOTE: `dart:html` is not available in `flutter test` (runs on the Dart VM,
// not a browser). The `desktop_drop` package bridges OS drag events on web via
// a JS interop layer that also requires a live browser; DropTarget renders as
// a transparent pass-through in VM tests and no interaction simulation is
// possible here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/chat_panel/drop_overlay.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: EchoTheme.darkTheme,
  darkTheme: EchoTheme.darkTheme,
  themeMode: ThemeMode.dark,
  home: Scaffold(body: Stack(children: [child])),
);

void main() {
  group('DropOverlay', () {
    testWidgets('is transparent when isDragOver is false', (tester) async {
      await tester.pumpWidget(_wrap(const DropOverlay(isDragOver: false)));
      await tester.pump();

      final animated = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animated.opacity, 0.0);
    });

    testWidgets('is opaque when isDragOver is true', (tester) async {
      await tester.pumpWidget(_wrap(const DropOverlay(isDragOver: true)));
      await tester.pump();

      final animated = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animated.opacity, 1.0);
    });

    testWidgets('shows "Drop file to send" label when dragging', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DropOverlay(isDragOver: true)));
      await tester.pump();

      expect(find.text('Drop file to send'), findsOneWidget);
    });

    testWidgets('overlay content is pointer-blocked when idle', (tester) async {
      // The overlay is in the tree at opacity-0; IgnorePointer ensures no tap
      // reaches the dimmed content while the user is not dragging.
      await tester.pumpWidget(_wrap(const DropOverlay(isDragOver: false)));
      await tester.pump();

      // Text node exists but is invisible (opacity-0 parent).
      expect(find.text('Drop file to send'), findsOneWidget);

      // Find the IgnorePointer that is a direct descendant of DropOverlay.
      final ignorePointers = tester.widgetList<IgnorePointer>(
        find.descendant(
          of: find.byType(DropOverlay),
          matching: find.byType(IgnorePointer),
        ),
      );
      // There is exactly one IgnorePointer inside DropOverlay and it always
      // blocks input (the overlay never allows pointer events, idle or active).
      expect(ignorePointers.length, 1);
      expect(ignorePointers.first.ignoring, isTrue);
    });

    testWidgets('upload icon is present in overlay', (tester) async {
      await tester.pumpWidget(_wrap(const DropOverlay(isDragOver: true)));
      await tester.pump();

      expect(find.byIcon(Icons.upload_file_outlined), findsOneWidget);
    });
  });
}
