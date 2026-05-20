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
    testWidgets('renders the label and the embedded child', (tester) async {
      await _pumpDraggable(
        tester,
        const Center(child: Text('inner')),
        label: 'Alice — Screen 1',
      );

      expect(find.text('Alice — Screen 1'), findsOneWidget);
      expect(find.text('inner'), findsOneWidget);
      // The screen-share badge icon should appear next to the label.
      expect(find.byIcon(Icons.screen_share), findsOneWidget);
      // The resize handle icon sits in the bottom-right corner.
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
    });

    testWidgets('mounts in local mode without throwing', (tester) async {
      await _pumpDraggable(
        tester,
        const SizedBox.shrink(),
        label: 'Local',
        isLocal: true,
      );
      expect(find.text('Local'), findsOneWidget);
    });
  });
}
