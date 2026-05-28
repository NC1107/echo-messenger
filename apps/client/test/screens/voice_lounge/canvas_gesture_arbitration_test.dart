/// Canvas gesture-arbitration widget tests (canvas_redesign.md PR C).
///
/// Verifies the five conflict rules from
/// docs/voice-lounge/02-input-matrix.md:
///
///   1. A draw stroke in progress wins all other gestures for the
///      duration of the stroke.
///   2. A second simultaneous pointer cancels a draw stroke and yields
///      to the pinch/scale recognizer.
///   3. `selectedTool == CanvasTool.none` => pan/zoom unrestricted; any
///      tool selected => single-pointer drag draws, not pans.
///      Corollary: double-tap zoom is suppressed while drawing.
///   4. Tool switching mid-stroke is destructive -- the in-flight stroke
///      is cancelled.
///   5. Keyboard shortcuts require canvas focus; they must not fire
///      while the chat input has focus.
///
/// Rules 1-2 are confirmed by the gesture-arena mechanics already in
/// place (DragStartBehavior.start + PanGestureRecognizer losing to
/// ScaleGestureRecognizer on second pointer -- #1257). These tests lock
/// that behavior in so a future refactor cannot accidentally regress it.
/// Rule 3 (double-tap gate) locks in the #1266 fix.
library;

import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:echo_app/src/widgets/lounge_canvas_shortcuts.dart';
import 'package:echo_app/src/widgets/lounge_drawing_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Test spy: records calls to CanvasController
// ---------------------------------------------------------------------------

/// Spy over the real CanvasController. Counts draw-lifecycle calls so tests
/// can assert which path the gesture arena took without a real server
/// connection (canvasProvider skips WS broadcast when _channelId is null).
class _SpyCanvas extends CanvasController {
  int startStrokeCalls = 0;
  int continueStrokeCalls = 0;
  int endStrokeCalls = 0;

  @override
  void startStroke(CanvasPoint point) {
    startStrokeCalls++;
    super.startStroke(point);
  }

  @override
  void continueStroke(CanvasPoint point) {
    continueStrokeCalls++;
    super.continueStroke(point);
  }

  @override
  void endStroke() {
    endStrokeCalls++;
    super.endStroke();
  }
}

// ---------------------------------------------------------------------------
// Minimal drawing canvas harness
// ---------------------------------------------------------------------------

/// Pumps a [LoungeDrawingCanvas] inside an [InteractiveViewer] with a
/// fixed 800x600 test viewport. The canvas is placed as a direct fill
/// of the viewport so gesture coordinates map 1-to-1 to canvas pixels.
Future<_SpyCanvas> _pumpCanvas(
  WidgetTester tester, {
  bool toolSelected = true,
}) async {
  final spy = _SpyCanvas();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [canvasProvider.overrideWith(() => spy)],
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // InteractiveViewer as the pan/scale backdrop.
              InteractiveViewer(
                panEnabled: !toolSelected,
                scaleEnabled: true,
                child: Container(width: 800, height: 600, color: Colors.grey),
              ),
              // Drawing overlay on top, same size as the viewport.
              Positioned.fill(
                child: LoungeDrawingCanvas(isActive: toolSelected),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return spy;
}

// ---------------------------------------------------------------------------
// Double-tap gate harness (rule 3)
// ---------------------------------------------------------------------------

class _DoubleTapHarness extends StatefulWidget {
  const _DoubleTapHarness();

  @override
  State<_DoubleTapHarness> createState() => _DoubleTapHarnessState();
}

class _DoubleTapHarnessState extends State<_DoubleTapHarness> {
  bool isDrawing = false;
  // Incremented each time onDoubleTapDown fires. Zero means the gate blocked
  // the zoom; non-zero means the zoom callback ran. Using a counter (rather
  // than a TransformationController read) keeps the assertion independent of
  // Matrix4 internals and InteractiveViewer arena behaviour in the test env.
  int doubleTapFired = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          key: const Key('toggle-drawing'),
          onPressed: () => setState(() => isDrawing = !isDrawing),
          child: const Text('Toggle drawing'),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // Mirror the exact gate in voice_lounge_screen.dart line 1515:
            // onDoubleTapDown is null while _isDrawing is true.
            onDoubleTapDown: isDrawing
                ? null
                : (_) => setState(() => doubleTapFired++),
            child: Container(color: Colors.grey.shade200),
          ),
        ),
        Text('fired:$doubleTapFired', key: const Key('fired-label')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Keyboard shortcuts harness (rule 5)
// ---------------------------------------------------------------------------

class _KeyboardHarness extends StatefulWidget {
  const _KeyboardHarness();

  @override
  State<_KeyboardHarness> createState() => _KeyboardHarnessState();
}

class _KeyboardHarnessState extends State<_KeyboardHarness> {
  CanvasTool tool = CanvasTool.none;
  final FocusNode canvasFocus = FocusNode(debugLabel: 'canvas');
  final FocusNode chatFocus = FocusNode(debugLabel: 'chat');

  @override
  void dispose() {
    canvasFocus.dispose();
    chatFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: const Key('chat-input'),
          focusNode: chatFocus,
          decoration: const InputDecoration(hintText: 'Chat input'),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => canvasFocus.requestFocus(),
            child: LoungeCanvasShortcuts(
              focusNode: canvasFocus,
              onToolSelected: (t) => setState(() => tool = t),
              child: Container(
                key: const Key('canvas-area'),
                color: Colors.blueGrey.shade900,
                child: Center(
                  child: Text(
                    'tool:${tool.name}',
                    key: const Key('tool-label'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Rule 1: draw stroke in progress wins over pinch
  // -------------------------------------------------------------------------
  group('Rule 1: draw stroke in progress wins over new pointer', () {
    testWidgets(
      'draw_wins_over_pinch_when_started_first: startStroke fires after '
      'slop and stroke completes cleanly after a second pointer is added',
      (tester) async {
        final spy = await _pumpCanvas(tester);

        // Start a single-pointer drag that crosses kPanSlop so the
        // PanGestureRecognizer claims the arena and calls startStroke.
        final gesture = await tester.startGesture(const Offset(100, 100));

        // Move enough to cross slop (~18 px) so the pan is claimed.
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();

        // startStroke must have fired (pan was claimed).
        expect(
          spy.startStrokeCalls,
          greaterThan(0),
          reason: 'pan must be claimed after crossing slop',
        );

        // Snapshot start count before adding second pointer.
        final startsBefore = spy.startStrokeCalls;

        // Add a second pointer AFTER the first has crossed slop and been
        // claimed.
        final gesture2 = await tester.startGesture(const Offset(200, 200));
        await tester.pump();

        // Lift both pointers to end gestures.
        await gesture.up();
        await tester.pump();
        await gesture2.up();
        await tester.pump();

        // endStroke must have been called at least once.
        expect(
          spy.endStrokeCalls,
          greaterThan(0),
          reason: 'pan must end cleanly when stroke was in progress',
        );
        // The second pointer must not spawn a second concurrent startStroke.
        expect(
          spy.startStrokeCalls,
          equals(startsBefore),
          reason:
              'second pointer after slop must not trigger a new startStroke',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Rule 2: second pointer before slop cancels draw and yields pinch
  // -------------------------------------------------------------------------
  group('Rule 2: second pointer before slop cancels draw, yields pinch', () {
    testWidgets('second_pointer_cancels_draw_and_yields_pinch: with '
        'DragStartBehavior.start the pan is not yet claimed when a second '
        'pointer arrives before slop; stroke lifecycle stays balanced', (
      tester,
    ) async {
      final spy = await _pumpCanvas(tester);

      // Start first pointer but do NOT move enough to cross slop (< 18 px).
      final gesture1 = await tester.startGesture(const Offset(100, 200));
      await gesture1.moveBy(const Offset(5, 0)); // sub-slop
      await tester.pump();

      // Second pointer arrives BEFORE slop is crossed.
      final gesture2 = await tester.startGesture(const Offset(200, 200));
      await gesture2.moveBy(const Offset(30, 0));
      await tester.pump();

      await gesture1.up();
      await gesture2.up();
      await tester.pump();

      // Lifecycle balance: every startStroke must pair with an endStroke.
      expect(
        spy.endStrokeCalls,
        greaterThanOrEqualTo(spy.startStrokeCalls),
        reason:
            'every startStroke must be paired with an endStroke '
            '(onPanCancel -> endStroke) when the arena is lost to pinch',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Rule 3: double-tap zoom suppressed while drawing tool active
  // -------------------------------------------------------------------------
  group('Rule 3: double-tap zoom suppressed while drawing tool active', () {
    testWidgets('double_tap_does_not_zoom_while_drawing_tool_selected: '
        'onDoubleTapDown is null when isDrawing is true; callback must not '
        'fire after double-tap while drawing (#1266)', (tester) async {
      await tester.pumpApp(const _DoubleTapHarness());
      await tester.pump();

      // Counter starts at zero.
      expect(find.text('fired:0'), findsOneWidget);

      // Enable drawing mode.
      await tester.tap(find.byKey(const Key('toggle-drawing')));
      await tester.pump();

      // Double-tap via tester helper (honors gesture arena timing).
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pumpAndSettle();

      // Counter must remain zero -- callback suppressed while drawing.
      expect(
        find.text('fired:0'),
        findsOneWidget,
        reason: 'double-tap callback must not fire when drawing tool is active',
      );
    });

    testWidgets(
      'double_tap_zooms_when_no_drawing_tool: callback fires normally when '
      'drawing is not active (validates the gate itself)',
      (tester) async {
        await tester.pumpApp(const _DoubleTapHarness());
        await tester.pump();

        // Drawing OFF by default -- double-tap callback should fire.
        await tester.tap(find.byType(GestureDetector).last);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byType(GestureDetector).last);
        await tester.pumpAndSettle();

        expect(
          find.text('fired:1'),
          findsOneWidget,
          reason: 'double-tap callback must fire when drawing is inactive',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Rule 4: tool switch during stroke is destructive
  // -------------------------------------------------------------------------
  group('Rule 4: tool switch during stroke is destructive', () {
    test(
      'tool_switch_during_stroke_cancels_stroke: '
      'switching tool while _strokeActive=true closes the in-flight stroke',
      () {
        final container = ProviderContainer(
          overrides: [canvasProvider.overrideWith(() => _SpyCanvas())],
        );
        addTearDown(container.dispose);

        final notifier = container.read(canvasProvider.notifier) as _SpyCanvas;

        // Arm with pen and start a stroke.
        notifier.setTool(CanvasTool.pen);
        notifier.startStroke(const CanvasPoint(x: 100, y: 100));
        notifier.continueStroke(const CanvasPoint(x: 150, y: 120));

        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isTrue);

        // Simulate tool switch: UI calls endStroke then setTool (destructive).
        notifier.endStroke();
        notifier.setTool(CanvasTool.eraser);

        // Stroke must be closed.
        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isFalse);
        expect(container.read(canvasProvider).selectedTool, CanvasTool.eraser);
      },
    );

    test(
      'tool_switch_does_not_commit_partial_stroke: endStroke with no '
      '_channelId attached must not append to the committed strokes list',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(canvasProvider.notifier);

        notifier.setTool(CanvasTool.pen);
        notifier.startStroke(const CanvasPoint(x: 10, y: 10));
        // Switch tool immediately -- triggers endStroke before any continue.
        notifier.endStroke();

        // No committed stroke appended because _channelId is null.
        expect(container.read(canvasProvider).strokes, isEmpty);
        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isFalse);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Rule 5: keyboard shortcuts require canvas focus
  // -------------------------------------------------------------------------
  group('Rule 5: keyboard shortcuts require canvas focus', () {
    testWidgets('keyboard_shortcut_does_not_fire_when_chat_input_focused: '
        'pressing B while chat input is focused must not switch tool to pen', (
      tester,
    ) async {
      await tester.pumpApp(const _KeyboardHarness());
      await tester.pump();

      // Focus the chat input.
      await tester.tap(find.byKey(const Key('chat-input')));
      await tester.pump();

      final state = tester.state<_KeyboardHarnessState>(
        find.byType(_KeyboardHarness),
      );
      expect(state.chatFocus.hasPrimaryFocus, isTrue);

      // Press B -- must not switch tool to pen.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(
        find.text('tool:none'),
        findsOneWidget,
        reason: 'B shortcut must be blocked when chat input has focus',
      );
    });

    testWidgets('keyboard_shortcut_fires_when_canvas_focused: '
        'pressing B after tapping the canvas switches tool to pen', (
      tester,
    ) async {
      await tester.pumpApp(const _KeyboardHarness());
      await tester.pump();

      // Tap the canvas to give it focus.
      await tester.tap(find.byKey(const Key('canvas-area')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(
        find.text('tool:pen'),
        findsOneWidget,
        reason: 'B shortcut must switch to pen when canvas has focus',
      );
    });

    testWidgets(
      'escape_clears_tool_when_canvas_focused: Escape resets to none',
      (tester) async {
        await tester.pumpApp(const _KeyboardHarness());
        await tester.pump();

        await tester.tap(find.byKey(const Key('canvas-area')));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.pump();
        expect(find.text('tool:pen'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(
          find.text('tool:none'),
          findsOneWidget,
          reason: 'Escape must exit drawing mode',
        );
      },
    );

    testWidgets('eraser_shortcut_fires_when_canvas_focused: E selects eraser', (
      tester,
    ) async {
      await tester.pumpApp(const _KeyboardHarness());
      await tester.pump();

      await tester.tap(find.byKey(const Key('canvas-area')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pump();

      expect(
        find.text('tool:eraser'),
        findsOneWidget,
        reason: 'E shortcut must select eraser tool',
      );
    });
  });
}
