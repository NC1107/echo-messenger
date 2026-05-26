import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/services/canvas_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CanvasExportService', () {
    test('encodes + decodes a snapshot losslessly', () {
      final original = const CanvasState(
        strokes: [
          CanvasStroke(
            id: 's1',
            color: '#FFFFFF',
            width: 3.5,
            points: [CanvasPoint(x: 0.1, y: 0.2), CanvasPoint(x: 0.3, y: 0.4)],
          ),
        ],
        images: [
          CanvasImage(
            id: 'i1',
            url: 'https://example.com/a.png',
            x: 0.2,
            y: 0.3,
            width: 0.25,
            height: 0.25,
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
      expect(decoded.images.first.width, 0.25);
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
