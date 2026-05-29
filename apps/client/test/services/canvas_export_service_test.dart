import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/services/canvas_export_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CanvasExportService.clampPixelRatio', () {
    test('returns requested ratio when image fits within maxDim', () {
      // 200x100 boundary at 2.0 → max dimension 400, well under 4096.
      final ratio = CanvasExportService.clampPixelRatio(
        const Size(200, 100),
        pixelRatio: 2.0,
        maxDim: 4096,
      );
      expect(ratio, closeTo(2.0, 0.0001));
    });

    test('clamps ratio so the longest side stays at maxDim', () {
      // 3000x2000 boundary at 2.0 → longest side would be 6000 > 4096.
      // Expected: 4096 / 3000 ≈ 1.3653.
      final ratio = CanvasExportService.clampPixelRatio(
        const Size(3000, 2000),
        pixelRatio: 2.0,
        maxDim: 4096,
      );
      expect(ratio, closeTo(4096 / 3000, 0.0001));
    });

    test('never returns below minRatio', () {
      // Boundary larger than maxDim itself (e.g. 10000px logical).
      final ratio = CanvasExportService.clampPixelRatio(
        const Size(10000, 10000),
        pixelRatio: 2.0,
        maxDim: 4096,
        minRatio: 0.5,
      );
      expect(ratio, greaterThanOrEqualTo(0.5));
    });

    test('handles zero-size boundary without throwing', () {
      final ratio = CanvasExportService.clampPixelRatio(
        Size.zero,
        pixelRatio: 2.0,
      );
      expect(ratio, equals(0.5)); // minRatio floor
    });

    test('portrait boundary clamps on height', () {
      // 1000x4000 boundary at 2.0 → longest side is 4000, result 8000 > 4096.
      // Expected: 4096 / 4000 = 1.024.
      final ratio = CanvasExportService.clampPixelRatio(
        const Size(1000, 4000),
        pixelRatio: 2.0,
        maxDim: 4096,
      );
      expect(ratio, closeTo(4096 / 4000, 0.0001));
    });
  });

  group('CanvasExportService', () {
    test('encodes + decodes a snapshot losslessly', () {
      // Coords are in absolute canvas-space pixels (kCanvasWidth × kCanvasHeight).
      final original = const CanvasState(
        strokes: [
          CanvasStroke(
            id: 's1',
            color: '#FFFFFF',
            width: 3.5,
            points: [
              CanvasPoint(x: 400, y: 800),
              CanvasPoint(x: 1200, y: 1600),
            ],
          ),
        ],
        images: [
          CanvasImage(
            id: 'i1',
            url: 'https://example.com/a.png',
            x: 800,
            y: 1200,
            width: 1024,
            height: 1024,
          ),
        ],
      );

      final json = CanvasExportService.encodeJson(original);
      final decoded = CanvasExportService.decodeJson(json);

      expect(decoded.strokes, hasLength(1));
      expect(decoded.strokes.first.id, 's1');
      expect(decoded.strokes.first.color, '#FFFFFF');
      expect(decoded.strokes.first.points, hasLength(2));
      expect(decoded.images, hasLength(1));
      expect(decoded.images.first.id, 'i1');
      expect(decoded.images.first.width, 1024);
    });

    test('rejects a snapshot with a wrong format_version', () {
      const payload = '{"format_version": 999, "strokes": [], "images": []}';
      expect(
        () => CanvasExportService.decodeJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing arrays', () {
      const payload = '{"format_version": 1}';
      expect(
        () => CanvasExportService.decodeJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-object root', () {
      expect(
        () => CanvasExportService.decodeJson('"hello"'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
