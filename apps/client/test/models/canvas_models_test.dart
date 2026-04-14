import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/canvas_models.dart';

void main() {
  group('CanvasPoint', () {
    test('round-trips through JSON', () {
      const point = CanvasPoint(x: 0.25, y: 0.75);
      final json = point.toJson();
      final restored = CanvasPoint.fromJson(json);
      expect(restored.x, closeTo(0.25, 1e-10));
      expect(restored.y, closeTo(0.75, 1e-10));
    });

    test('fromJson accepts num (int or double)', () {
      final p = CanvasPoint.fromJson({'x': 1, 'y': 0});
      expect(p.x, 1.0);
      expect(p.y, 0.0);
    });
  });

  group('CanvasStroke', () {
    test('pen stroke round-trips through JSON', () {
      final stroke = CanvasStroke(
        id: 'stroke-1',
        color: '#FF0000',
        width: 4.0,
        points: const [
          CanvasPoint(x: 0.1, y: 0.2),
          CanvasPoint(x: 0.3, y: 0.4),
        ],
        kind: StrokeKind.pen,
      );

      final json = stroke.toJson();
      final restored = CanvasStroke.fromJson(json);

      expect(restored.id, 'stroke-1');
      expect(restored.color, '#FF0000');
      expect(restored.width, 4.0);
      expect(restored.points.length, 2);
      expect(restored.kind, StrokeKind.pen);
    });

    test('eraser stroke preserves kind', () {
      final stroke = CanvasStroke(
        id: 'e-1',
        color: '#00000000',
        width: 10.0,
        points: const [CanvasPoint(x: 0.5, y: 0.5)],
        kind: StrokeKind.eraser,
      );
      final json = stroke.toJson();
      final restored = CanvasStroke.fromJson(json);
      expect(restored.kind, StrokeKind.eraser);
    });

    test('missing kind field defaults to pen', () {
      final json = {
        'id': 'x',
        'color': '#FFFFFF',
        'width': 2.0,
        'points': <dynamic>[],
      };
      final stroke = CanvasStroke.fromJson(json);
      expect(stroke.kind, StrokeKind.pen);
    });
  });

  group('CanvasImage', () {
    test('round-trips through JSON', () {
      const img = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 0.1,
        y: 0.2,
        width: 0.3,
        height: 0.2,
      );

      final json = img.toJson();
      final restored = CanvasImage.fromJson(json);

      expect(restored.id, 'img-1');
      expect(restored.url, 'https://example.com/img.png');
      expect(restored.x, closeTo(0.1, 1e-10));
      expect(restored.y, closeTo(0.2, 1e-10));
      expect(restored.width, closeTo(0.3, 1e-10));
      expect(restored.height, closeTo(0.2, 1e-10));
    });

    test('copyWith updates only specified fields', () {
      const img = CanvasImage(
        id: 'img-2',
        url: 'https://example.com/foo.png',
        x: 0.0,
        y: 0.0,
        width: 0.2,
        height: 0.1,
      );
      final moved = img.copyWith(x: 0.5, y: 0.6);
      expect(moved.id, 'img-2');
      expect(moved.url, 'https://example.com/foo.png');
      expect(moved.x, closeTo(0.5, 1e-10));
      expect(moved.y, closeTo(0.6, 1e-10));
      // Unchanged
      expect(moved.width, closeTo(0.2, 1e-10));
      expect(moved.height, closeTo(0.1, 1e-10));
    });
  });

  group('AvatarPosition', () {
    test('copyWith updates coordinates', () {
      const pos = AvatarPosition(userId: 'u1', x: 0.5, y: 0.5);
      final moved = pos.copyWith(x: 0.8, y: 0.2);
      expect(moved.userId, 'u1');
      expect(moved.x, closeTo(0.8, 1e-10));
      expect(moved.y, closeTo(0.2, 1e-10));
    });
  });

  group('CanvasState', () {
    test('default state is empty and not loaded', () {
      const state = CanvasState();
      expect(state.strokes, isEmpty);
      expect(state.images, isEmpty);
      expect(state.avatarPositions, isEmpty);
      expect(state.activePoints, isEmpty);
      expect(state.selectedTool, CanvasTool.pen);
      expect(state.isLoaded, isFalse);
    });

    test('copyWith replaces only given fields', () {
      const state = CanvasState();
      final updated = state.copyWith(
        isLoaded: true,
        selectedTool: CanvasTool.eraser,
        currentColor: Color(0xFFFF0000),
        strokeWidth: 8.0,
      );
      expect(updated.isLoaded, isTrue);
      expect(updated.selectedTool, CanvasTool.eraser);
      expect(
        updated.currentColor.toARGB32(),
        const Color(0xFFFF0000).toARGB32(),
      );
      expect(updated.strokeWidth, 8.0);
      // Unchanged fields
      expect(updated.strokes, isEmpty);
      expect(updated.images, isEmpty);
    });

    test('copyWith strokes appends correctly', () {
      const state = CanvasState();
      final stroke = CanvasStroke(
        id: 's1',
        color: '#00FF00',
        width: 3.0,
        points: const [CanvasPoint(x: 0.0, y: 0.0)],
      );
      final updated = state.copyWith(strokes: [stroke]);
      expect(updated.strokes.length, 1);
      expect(updated.strokes.first.id, 's1');
    });
  });
}
