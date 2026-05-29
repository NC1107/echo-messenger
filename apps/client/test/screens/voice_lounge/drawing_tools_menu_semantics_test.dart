/// Widget test that asserts Semantics labels on canvas drawing-tool icons.
///
/// These exact strings are relied upon by the voice-lounge mobile audit spec
/// (tests/e2e/voice_lounge_mobile_audit.spec.ts) to locate and tap tool
/// buttons by accessible name instead of approximate pixel coordinates. Any
/// rename of a label string MUST update this test, the audit spec comment, and
/// the task description so the three stay in sync.
///
/// Cited from: tests/e2e/output/mobile-audit-report.md (Known gaps section).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/canvas_models.dart'
    show CanvasState, CanvasTool;
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:echo_app/src/screens/voice_lounge/drawing_tools_menu.dart';

import '../../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Minimal CanvasController stub that satisfies the menu's ref.read calls.
// ---------------------------------------------------------------------------

class _StubCanvasNotifier extends CanvasController {
  @override
  CanvasState build() => const CanvasState(selectedTool: CanvasTool.pen);

  @override
  void setTool(CanvasTool tool) {}

  @override
  void setColor(Color color) {}

  @override
  void setStrokeWidth(double w) {}

  @override
  void clearMyDrawings() {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a Finder for a Semantics node carrying [label] and button=true.
Finder _semButton(String label) => find.bySemanticsLabel(label);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  Future<void> pumpMenu(WidgetTester tester) async {
    await tester.pumpApp(
      DrawingToolsMenu(
        onToggleDrawing: () {},
        isDrawing: false,
        conversationId: 'test-conv',
      ),
      overrides: [
        canvasControllerProvider.overrideWith(_StubCanvasNotifier.new),
      ],
    );
    await tester.pumpAndSettle();
  }

  group('DrawingToolsMenu – Semantics labels', () {
    testWidgets('Pen tool button has correct semantics label', (tester) async {
      await pumpMenu(tester);
      expect(_semButton('Pen tool'), findsOneWidget);
    });

    testWidgets('Highlighter tool button has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      expect(_semButton('Highlighter tool'), findsOneWidget);
    });

    testWidgets('Eraser tool button has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      expect(_semButton('Eraser tool'), findsOneWidget);
    });

    testWidgets('Line tool button has correct semantics label', (tester) async {
      await pumpMenu(tester);
      expect(_semButton('Line tool'), findsOneWidget);
    });

    testWidgets('Rectangle tool button has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      expect(_semButton('Rectangle tool'), findsOneWidget);
    });

    testWidgets('Ellipse tool button has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      expect(_semButton('Ellipse tool'), findsOneWidget);
    });

    testWidgets('Text tool button has correct semantics label', (tester) async {
      await pumpMenu(tester);
      expect(_semButton('Text tool'), findsOneWidget);
    });

    testWidgets('Color picker section has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      // Container-level Semantics nodes are found via the widget tree rather
      // than the rendered semantics tree; verify the Semantics widget is present.
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.label == 'Color picker'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Stroke width section has correct semantics label', (
      tester,
    ) async {
      await pumpMenu(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.label == 'Stroke width'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('all 7 tool icons are individually labelled', (tester) async {
      await pumpMenu(tester);
      const toolLabels = [
        'Pen tool',
        'Highlighter tool',
        'Eraser tool',
        'Line tool',
        'Rectangle tool',
        'Ellipse tool',
        'Text tool',
      ];
      for (final label in toolLabels) {
        expect(
          _semButton(label),
          findsOneWidget,
          reason: '$label must have a Semantics button label',
        );
      }
    });
  });
}
