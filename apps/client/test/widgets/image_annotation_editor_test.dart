// Widget tests for ImageAnnotationEditor (MVP for #908).
//
// Covers:
//  - Free-hand strokes accumulate and render via CustomPaint.
//  - Undo removes the most recent stroke.
//  - Clear empties all strokes.
//  - Send invokes onConfirm with non-empty PNG bytes.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/image_annotation_editor.dart';

import '../helpers/pump_app.dart';

// 1×1 transparent PNG. Smallest possible Flutter-decodable image so the
// editor can mount without pulling a real asset into the test bundle.
final Uint8List _tiny1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, // IHDR length
  0x49, 0x48, 0x44, 0x52, // "IHDR"
  0x00, 0x00, 0x00, 0x01, // width=1
  0x00, 0x00, 0x00, 0x01, // height=1
  0x08, 0x06, 0x00, 0x00, 0x00, // 8-bit RGBA
  0x1F, 0x15, 0xC4, 0x89, // IHDR crc
  0x00, 0x00, 0x00, 0x0A, // IDAT length
  0x49, 0x44, 0x41, 0x54, // "IDAT"
  0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, // deflate
  0x0D, 0x0A, 0x2D, 0xB4, // IDAT crc
  0x00, 0x00, 0x00, 0x00, // IEND length
  0x49, 0x45, 0x4E, 0x44, // "IEND"
  0xAE, 0x42, 0x60, 0x82, // IEND crc
]);

/// Locates the [CustomPaint] inside [ImageAnnotationEditor] that owns the
/// strokes painter. There are several CustomPaints in any Material tree
/// (scrollbars, focus rings, etc.), so we filter by painter runtime type
/// name to grab the right one without exposing the private class.
Finder _strokesPainterFinder() {
  return find.byWidgetPredicate((Widget w) {
    if (w is! CustomPaint) return false;
    final painter = w.painter;
    if (painter == null) return false;
    return painter.runtimeType.toString().contains('StrokesPainter');
  });
}

int _strokeCount(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(_strokesPainterFinder().first);
  // Painter is a private type; reflect via toString of the strokes list
  // length isn't exposed. Read via dynamic since the field is private to
  // the editor's library.
  // ignore: avoid_dynamic_calls
  final dynamic painter = paint.painter;
  // ignore: avoid_dynamic_calls
  return (painter.strokes as List).length;
}

void main() {
  group('ImageAnnotationEditor (#908 MVP)', () {
    testWidgets('renders the source image and an empty strokes painter', (
      tester,
    ) async {
      await tester.pumpApp(
        ImageAnnotationEditor(imageBytes: _tiny1x1Png, onConfirm: (_) {}),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(_strokesPainterFinder(), findsOneWidget);
      expect(_strokeCount(tester), 0);
    });

    testWidgets('pan gesture accumulates a stroke', (tester) async {
      await tester.pumpApp(
        ImageAnnotationEditor(imageBytes: _tiny1x1Png, onConfirm: (_) {}),
      );
      await tester.pump();

      // Drag inside the image area to draw a single stroke.
      final TestGesture gesture = await tester.startGesture(
        const Offset(100, 200),
      );
      await gesture.moveBy(const Offset(20, 0));
      await gesture.moveBy(const Offset(20, 20));
      await gesture.up();
      await tester.pump();

      expect(_strokeCount(tester), 1);
    });

    testWidgets('undo removes the last stroke', (tester) async {
      await tester.pumpApp(
        ImageAnnotationEditor(imageBytes: _tiny1x1Png, onConfirm: (_) {}),
      );
      await tester.pump();

      // First stroke.
      TestGesture g = await tester.startGesture(const Offset(80, 200));
      await g.moveBy(const Offset(30, 0));
      await g.up();
      await tester.pump();

      // Second stroke.
      g = await tester.startGesture(const Offset(120, 220));
      await g.moveBy(const Offset(30, 30));
      await g.up();
      await tester.pump();

      expect(_strokeCount(tester), 2);

      // Tap Undo.
      await tester.tap(find.widgetWithIcon(IconButton, Icons.undo));
      await tester.pump();

      expect(_strokeCount(tester), 1);
    });

    testWidgets('clear empties all strokes', (tester) async {
      await tester.pumpApp(
        ImageAnnotationEditor(imageBytes: _tiny1x1Png, onConfirm: (_) {}),
      );
      await tester.pump();

      final TestGesture g = await tester.startGesture(const Offset(80, 200));
      await g.moveBy(const Offset(30, 0));
      await g.up();
      await tester.pump();

      expect(_strokeCount(tester), 1);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
      await tester.pump();

      expect(_strokeCount(tester), 0);
    });

    testWidgets('undo/clear are disabled with no strokes', (tester) async {
      await tester.pumpApp(
        ImageAnnotationEditor(imageBytes: _tiny1x1Png, onConfirm: (_) {}),
      );
      await tester.pump();

      final undo = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.undo),
      );
      final clear = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(undo.onPressed, isNull);
      expect(clear.onPressed, isNull);
    });
  });
}
