// Tests for the narrow-screen edge-swipe gesture that returns the user from
// the chat panel to the conversation list (#183).
//
// The production implementation lives in HomeScreen._buildNarrowChatPanel.
// We exercise the same gesture parameters (edge zone = 60 px, threshold = 60 px)
// with a minimal stateful harness so the test has no provider dependencies.

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Mirrors the swipe constants from _HomeScreenState.
const double _edgeSwipeZone = 60;
const double _edgeSwipeThreshold = 60;

/// Maximum translation distance for the peek panel.
const double _peekMaxWidth = 80.0;

/// Keys used to identify which panel is visible.
const Key _chatKey = Key('chat-panel');
const Key _convKey = Key('conv-list');

/// Key for the peek panel that appears during a live drag.
const Key _peekKey = Key('peek-panel');

/// A minimal replica of the narrow chat/conversation-list navigation logic
/// in HomeScreen._buildNarrowChatPanel.  Uses the same widget structure
/// (Scaffold → SafeArea → PopScope → GestureDetector → Stack) so the test
/// exercises the real gesture path without any Riverpod provider dependencies.
class _NarrowNavigationHarness extends StatefulWidget {
  const _NarrowNavigationHarness();

  @override
  State<_NarrowNavigationHarness> createState() =>
      _NarrowNavigationHarnessState();
}

class _NarrowNavigationHarnessState extends State<_NarrowNavigationHarness>
    with SingleTickerProviderStateMixin {
  // 0 = conversation list, 1 = chat panel (same semantics as _narrowPanelIndex)
  int _panelIndex = 1;
  double? _swipeStartX;
  double _swipeProgress = 0.0;

  late final AnimationController _snapController;

  @override
  void initState() {
    super.initState();
    _snapController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 150),
        )..addListener(() {
          if (mounted) setState(() => _swipeProgress = _snapController.value);
        });
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_panelIndex == 0) {
      // Conversation list panel
      return const Scaffold(
        key: _convKey,
        body: ColoredBox(color: Colors.blue, child: SizedBox.expand()),
      );
    }

    // Chat panel content.
    const chatContent = ColoredBox(
      key: _chatKey,
      color: Colors.grey,
      child: SizedBox.expand(),
    );

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
              _snapController.stop();
            },
            onHorizontalDragUpdate: (details) {
              if (_swipeStartX == null) return;
              if (_swipeStartX! >= _edgeSwipeZone) return;

              final deltaX = details.globalPosition.dx - _swipeStartX!;

              if (deltaX > _edgeSwipeThreshold) {
                _swipeStartX = null;
                setState(() {
                  _swipeProgress = 0.0;
                  _panelIndex = 0;
                });
                return;
              }

              final progress =
                  (deltaX.clamp(0.0, _edgeSwipeThreshold) /
                  _edgeSwipeThreshold);
              setState(() => _swipeProgress = progress);
            },
            onHorizontalDragEnd: (_) {
              if (_swipeProgress > 0.0) {
                _snapController.value = _swipeProgress;
                _snapController.animateBack(0.0, curve: Curves.easeOut);
              }
              _swipeStartX = null;
            },
            child: Stack(
              children: [
                chatContent,
                if (_swipeProgress > 0.0)
                  Positioned(
                    key: _peekKey,
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: _peekMaxWidth,
                    child: Transform.translate(
                      offset: Offset(
                        (1.0 - _swipeProgress) * -_peekMaxWidth,
                        0,
                      ),
                      child: Opacity(
                        opacity: _swipeProgress,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ),
              ],
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

    testWidgets(
      'peek panel appears during an in-progress drag and disappears after snap-back',
      (tester) async {
        await pump(tester);

        // Simulate a drag that reaches 50 % of the threshold without completing.
        // We use TestPointer so we can hold the pointer mid-drag before releasing.
        final pointer = TestPointer(1, PointerDeviceKind.touch);
        const startOffset = Offset(20, 300);
        const midOffset = Offset(
          20 + _edgeSwipeThreshold * 0.5,
          300,
        ); // 50 % progress

        // Press and move to mid point.
        await tester.sendEventToBinding(pointer.down(startOffset));
        await tester.pump();
        await tester.sendEventToBinding(pointer.move(midOffset));
        await tester.pump();

        // Peek panel should now be present (progress > 0).
        expect(find.byKey(_peekKey), findsOneWidget);
        // Chat panel still behind the peek layer.
        expect(find.byKey(_chatKey), findsOneWidget);
        // Not navigated yet.
        expect(find.byKey(_convKey), findsNothing);

        // Release without crossing the threshold.
        await tester.sendEventToBinding(pointer.up());
        // Let the snap-back animation complete.
        await tester.pumpAndSettle();

        // After snap-back, the peek panel must be gone and chat still shown.
        expect(find.byKey(_peekKey), findsNothing);
        expect(find.byKey(_chatKey), findsOneWidget);
        expect(find.byKey(_convKey), findsNothing);
      },
    );
  });
}
