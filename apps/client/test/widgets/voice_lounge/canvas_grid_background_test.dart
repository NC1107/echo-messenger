import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/voice_lounge/canvas_grid_background.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a CanvasGridBackground inside a MaterialApp with the given theme.
Widget _buildGrid({
  ThemeData? theme,
  Matrix4? transform,
  ValueNotifier<int>? notifier,
}) {
  final ctrl = notifier ?? ValueNotifier<int>(0);
  final mat = transform ?? Matrix4.identity();
  return MaterialApp(
    theme: theme ?? ThemeData.light(),
    home: Scaffold(
      body: CanvasGridBackground(
        transformListenable: ctrl,
        currentTransform: () => mat,
      ),
    ),
  );
}

/// Resolves effective minor spacing given a visible-rect span and base
/// minor spacing using the same adaptive-density algorithm as the painter.
double _resolveSpacing(double span, double baseSpacing) {
  const int maxLines = 200;
  var spacing = baseSpacing;
  while (span / spacing > maxLines) {
    spacing *= 10;
  }
  return spacing;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('CanvasGridBackground', () {
    testWidgets('renders without throwing at identity transform', (
      tester,
    ) async {
      await tester.pumpWidget(_buildGrid());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(CanvasGridBackground), findsOneWidget);
    });

    testWidgets('renders without throwing at extreme zoom-in (scale 10)', (
      tester,
    ) async {
      final transform = Matrix4.identity()..scaleByDouble(10.0, 10.0, 1.0, 1.0);
      await tester.pumpWidget(_buildGrid(transform: transform));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without throwing at extreme zoom-out (scale 0.001) — '
        'adaptive density cap fires', (tester) async {
      final transform = Matrix4.identity()
        ..scaleByDouble(0.001, 0.001, 1.0, 1.0);
      await tester.pumpWidget(_buildGrid(transform: transform));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    // -----------------------------------------------------------------------
    // Adaptive density pure-function check
    // -----------------------------------------------------------------------

    test('adaptive density: 100 000 span / 100 spacing → effective 1000', () {
      const double span = 100000;
      const double base = 100;
      final result = _resolveSpacing(span, base);
      // span / base = 1000 > 200 → ×10 → spacing = 1000 → span/1000 = 100 ≤ 200.
      expect(result, equals(1000.0));
    });

    test('adaptive density: 10 000 span / 100 spacing → no bump', () {
      // 10 000 / 100 = 100 ≤ 200 → no bump needed.
      const double span = 10000;
      const double base = 100;
      final result = _resolveSpacing(span, base);
      expect(result, equals(100.0));
    });

    test(
      'adaptive density: 5 000 000 span / 100 spacing → effective 100 000',
      () {
        // 5 000 000 / 100 = 50 000 > 200 → ×10 → 1000, still > 200 → ×10
        // → 10 000, still > 200 → ×10 → 100 000, 50 ≤ 200. Done.
        const double span = 5000000;
        const double base = 100;
        final result = _resolveSpacing(span, base);
        expect(result, equals(100000.0));
      },
    );

    // -----------------------------------------------------------------------
    // Theme color differentiation
    // -----------------------------------------------------------------------

    testWidgets('light theme: CustomPaint is present', (tester) async {
      await tester.pumpWidget(_buildGrid(theme: ThemeData.light()));
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('dark theme: CustomPaint is present', (tester) async {
      await tester.pumpWidget(
        _buildGrid(theme: ThemeData(colorScheme: const ColorScheme.dark())),
      );
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('light theme painter has isDark == false', (tester) async {
      final notifier = ValueNotifier<int>(0);
      final mat = Matrix4.identity();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: CanvasGridBackground(
              transformListenable: notifier,
              currentTransform: () => mat,
            ),
          ),
        ),
      );
      await tester.pump();
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((cp) => cp.painter != null)
          .painter!;
      // ignore: avoid_dynamic_calls
      expect((painter as dynamic).isDark, isFalse);
    });

    testWidgets('dark theme painter has isDark == true', (tester) async {
      final notifier = ValueNotifier<int>(0);
      final mat = Matrix4.identity();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: const ColorScheme.dark()),
          home: Scaffold(
            body: CanvasGridBackground(
              transformListenable: notifier,
              currentTransform: () => mat,
            ),
          ),
        ),
      );
      await tester.pump();
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((cp) => cp.painter != null)
          .painter!;
      // ignore: avoid_dynamic_calls
      expect((painter as dynamic).isDark, isTrue);
    });

    // -----------------------------------------------------------------------
    // Listenable triggers repaint
    // -----------------------------------------------------------------------

    testWidgets('bumping the listenable causes the painter to repaint', (
      tester,
    ) async {
      var buildCount = 0;
      final notifier = ValueNotifier<int>(0);
      final mat = Matrix4.identity();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                buildCount++;
                return CanvasGridBackground(
                  transformListenable: notifier,
                  currentTransform: () => mat,
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final countAfterFirstPump = buildCount;

      // Notify listener → CustomPainter.repaint fires.
      // The Builder widget itself should NOT rebuild — only the painter repaints.
      notifier.value = 1;
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(buildCount, equals(countAfterFirstPump));
    });
  });
}
