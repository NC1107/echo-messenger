import 'package:echo_app/src/widgets/voice_lounge/canvas_minimap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Offset?> _pumpAndTap(
  WidgetTester tester, {
  required Matrix4 transform,
  required Size viewportSize,
  Offset? tapAt,
}) async {
  Offset? recentered;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: CanvasMinimap(
              transform: ValueNotifier<Matrix4>(transform),
              viewportSize: viewportSize,
              onRecenter: (p) => recentered = p,
            ),
          ),
        ),
      ),
    ),
  );
  if (tapAt == null) {
    await tester.tap(find.byType(CanvasMinimap));
  } else {
    await tester.tapAt(tapAt);
  }
  await tester.pump();
  return recentered;
}

void main() {
  group('CanvasMinimap', () {
    testWidgets('renders without content', (tester) async {
      await _pumpAndTap(
        tester,
        transform: Matrix4.identity(),
        viewportSize: const Size(400, 300),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CanvasMinimap), findsOneWidget);
    });

    testWidgets('tapping the centre recenters on the viewport centre', (
      tester,
    ) async {
      // Identity transform + 400x300 viewport → the visible canvas region is
      // (0,0)-(400,300), so its centre is (200,150). Tapping the minimap
      // centre must recenter the main view there.
      final recentered = await _pumpAndTap(
        tester,
        transform: Matrix4.identity(),
        viewportSize: const Size(400, 300),
      );
      final r = recentered;
      expect(r, isNotNull);
      expect(r!.dx, closeTo(200, 2));
      expect(r.dy, closeTo(150, 2));
    });

    testWidgets('recenter point follows a panned/zoomed transform', (
      tester,
    ) async {
      // Zoomed 2x and translated so the visible region is offset into the
      // canvas. Visible canvas region = unproject of the screen corners:
      // with scale 2 and translation (-1000,-800), screen (0,0)→canvas
      // (500,400) and screen (400,300)→canvas (700,550); centre (600,475).
      final t = Matrix4.identity()
        ..scaleByDouble(2, 2, 2, 1)
        ..setTranslationRaw(-1000, -800, 0);
      final recentered = await _pumpAndTap(
        tester,
        transform: t,
        viewportSize: const Size(400, 300),
      );
      final r = recentered;
      expect(r, isNotNull);
      expect(r!.dx, closeTo(600, 3));
      expect(r.dy, closeTo(475, 3));
    });
  });
}
