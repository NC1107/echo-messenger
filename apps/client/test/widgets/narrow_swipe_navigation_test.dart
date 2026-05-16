// Tests for the narrow-screen edge-swipe gesture that returns the user from
// the chat panel to the conversation list (#183).
//
// The production implementation lives in HomeScreen._buildNarrowChatPanel.
// We exercise the same gesture parameters (edge zone = 60 px, threshold = 60 px)
// with a minimal stateful harness so the test has no provider dependencies.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Mirrors the swipe constants from _HomeScreenState.
const double _edgeSwipeZone = 60;
const double _edgeSwipeThreshold = 60;

/// Keys used to identify which panel is visible.
const Key _chatKey = Key('chat-panel');
const Key _convKey = Key('conv-list');

/// A minimal replica of the narrow chat/conversation-list navigation logic
/// in HomeScreen._buildNarrowChatPanel.  Uses the same widget structure
/// (Scaffold → SafeArea → PopScope → GestureDetector) so the test exercises
/// the real gesture path without any Riverpod provider dependencies.
class _NarrowNavigationHarness extends StatefulWidget {
  const _NarrowNavigationHarness();

  @override
  State<_NarrowNavigationHarness> createState() =>
      _NarrowNavigationHarnessState();
}

class _NarrowNavigationHarnessState extends State<_NarrowNavigationHarness> {
  // 0 = conversation list, 1 = chat panel (same semantics as _narrowPanelIndex)
  int _panelIndex = 1;
  double? _swipeStartX;

  @override
  Widget build(BuildContext context) {
    if (_panelIndex == 0) {
      // Conversation list panel
      return const Scaffold(
        key: _convKey,
        body: ColoredBox(color: Colors.blue, child: SizedBox.expand()),
      );
    }

    // Chat panel — mirrors HomeScreen._buildNarrowChatPanel structure exactly.
    return Scaffold(
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _panelIndex = 0);
          },
          child: GestureDetector(
            onHorizontalDragStart: (details) {
              _swipeStartX = details.globalPosition.dx;
            },
            onHorizontalDragUpdate: (details) {
              if (_swipeStartX != null &&
                  _swipeStartX! < _edgeSwipeZone &&
                  details.globalPosition.dx - _swipeStartX! >
                      _edgeSwipeThreshold) {
                _swipeStartX = null;
                setState(() => _panelIndex = 0);
              }
            },
            onHorizontalDragEnd: (_) {},
            // ColoredBox (not SizedBox) so the render object participates in
            // hit testing and gesture events reach the GestureDetector.
            child: const ColoredBox(
              key: _chatKey,
              color: Colors.grey,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('narrow-screen edge swipe (#183)', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _NarrowNavigationHarness()),
      );
    }

    testWidgets('chat panel is shown initially', (tester) async {
      await pump(tester);
      expect(find.byKey(_chatKey), findsOneWidget);
      expect(find.byKey(_convKey), findsNothing);
    });

    testWidgets('swipe right from left edge navigates to conversation list', (
      tester,
    ) async {
      await pump(tester);

      // Drag starts inside the 60 px edge zone and ends 10 px past the
      // 60 px threshold — sufficient to trigger navigation.
      await tester.dragFrom(
        const Offset(20, 300), // startX=20 is inside the 60 px edge zone
        const Offset(_edgeSwipeThreshold + 10, 0), // delta past threshold
      );
      await tester.pump();

      expect(find.byKey(_convKey), findsOneWidget);
      expect(find.byKey(_chatKey), findsNothing);
    });

    testWidgets('swipe right starting outside edge zone does not navigate', (
      tester,
    ) async {
      await pump(tester);

      // startX is outside the 60 px edge zone — gesture should be ignored.
      await tester.dragFrom(
        const Offset(_edgeSwipeZone + 20, 300),
        const Offset(200, 0),
      );
      await tester.pump();

      expect(find.byKey(_chatKey), findsOneWidget);
      expect(find.byKey(_convKey), findsNothing);
    });

    testWidgets('short swipe from left edge does not navigate', (tester) async {
      await pump(tester);

      // startX inside edge zone but delta is 10 px short of the threshold.
      await tester.dragFrom(
        const Offset(20, 300),
        const Offset(_edgeSwipeThreshold - 10, 0),
      );
      await tester.pump();

      expect(find.byKey(_chatKey), findsOneWidget);
      expect(find.byKey(_convKey), findsNothing);
    });
  });
}
