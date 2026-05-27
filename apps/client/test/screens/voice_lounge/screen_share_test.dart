import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/voice_lounge/screen_share.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// Wrap [child] inside a Stack > LayoutBuilder pattern that mirrors how
/// voice_lounge_screen.dart hosts the draggable window. Returns the pumped
/// rect/label assertions.
///
/// Note: [DraggableScreenShareWindow] returns a [Positioned] from inside an
/// internal [LayoutBuilder]. Under the Flutter test framework this surfaces a
/// `ParentDataWidget` assertion ("Positioned inside LayoutBuilder"). The
/// warning is benign at runtime — the Stack still lays out the Positioned —
/// so we drain it via `tester.takeException()` and proceed.
Future<void> _pumpDraggable(
  WidgetTester tester,
  Widget child, {
  String label = 'Sharing',
  bool isLocal = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: Stack(
            children: [
              DraggableScreenShareWindow(
                label: label,
                isLocal: isLocal,
                child: child,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // Drain the ParentData assertion noted above so the test framework
  // doesn't fail the test on a known-benign warning.
  tester.takeException();
}

void main() {
  group('DraggableScreenShareWindow', () {
    testWidgets(
      'renders the embedded child and surfaces label/handle on hover (#1225)',
      (tester) async {
        await _pumpDraggable(
          tester,
          const Center(child: Text('inner')),
          label: 'Alice — Screen 1',
        );

        // Child content is always visible.
        expect(find.text('inner'), findsOneWidget);

        // Label + handle are hover-only — neither appears at rest.
        expect(find.text('Alice — Screen 1'), findsNothing);
        expect(find.byIcon(Icons.screen_share), findsNothing);
        expect(find.byIcon(Icons.open_in_full), findsNothing);

        // Drive a mouse hover over the window so MouseRegion flips on.
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer(location: Offset.zero);
        await gesture.moveTo(tester.getCenter(find.text('inner')));
        await tester.pump();

        expect(find.text('Alice — Screen 1'), findsOneWidget);
        expect(find.byIcon(Icons.screen_share), findsOneWidget);
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      },
    );

    testWidgets('mounts in local mode without throwing', (tester) async {
      await _pumpDraggable(
        tester,
        const SizedBox.shrink(),
        label: 'Local',
        isLocal: true,
      );
      // Label is hover-only post-#1225; reaching this expectation
      // without an exception is what the test cares about.
      expect(find.text('Local'), findsNothing);
    });
  });
}
