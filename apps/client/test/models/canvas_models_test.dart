import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/canvas_models.dart';

void main() {
  group('CanvasPoint', () {
    test('canvas dimensions are the 100k-px figma-style surface', () {
      // The 100k value is the "feels infinite" virtual canvas; in 2026-05
      // we bumped from the original 4096 to give users true Figma-style
      // pan/zoom. The auto-fit-on-join logic frames the bbox of existing
      // content so users never have to find the corner.
      expect(kCanvasWidth, 100000);
      expect(kCanvasHeight, 100000);
    });

    test('round-trips through JSON in canvas-space pixels', () {
      const point = CanvasPoint(x: 1024.0, y: 3072.0);
      final json = point.toJson();
      final restored = CanvasPoint.fromJson(json);
      expect(restored.x, closeTo(1024.0, 1e-9));
      expect(restored.y, closeTo(3072.0, 1e-9));
    });

    test('fromJson accepts num (int or double)', () {
      // Use a value > 1.0 so the legacy-coord migration does not rescale.
      final p = CanvasPoint.fromJson({'x': 100, 'y': 200});
      expect(p.x, 100.0);
      expect(p.y, 200.0);
    });

    test('legacy 0..1 normalized coords migrate to legacy-4096 space', () {
      // Strokes persisted before the fixed-size canvas migration stored
      // x/y as fractions of the participant's viewport. After the 100k
      // bump, those are rescaled by 4096 (NOT by kCanvasWidth) so the
      // old drawings stay in their original spatial relationships in
      // the top-left 4% of the new 100k space. Auto-fit-to-content on
      // join zooms users to that region naturally.
      final p = CanvasPoint.fromJson({'x': 0.5, 'y': 0.25});
      expect(p.x, closeTo(2048.0, 1e-9));
      expect(p.y, closeTo(1024.0, 1e-9));
    });
  });

  group('CanvasStroke', () {
    test('pen stroke round-trips through JSON', () {
      final stroke = const CanvasStroke(
        id: 'stroke-1',
        color: '#FF0000',
        width: 4.0,
        points: [CanvasPoint(x: 0.1, y: 0.2), CanvasPoint(x: 0.3, y: 0.4)],
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
      final stroke = const CanvasStroke(
        id: 'e-1',
        color: '#00000000',
        width: 10.0,
        points: [CanvasPoint(x: 0.5, y: 0.5)],
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
    test('round-trips through JSON in canvas-space pixels', () {
      const img = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 400,
        y: 800,
        width: 1200,
        height: 800,
      );

      final json = img.toJson();
      final restored = CanvasImage.fromJson(json);

      expect(restored.id, 'img-1');
      expect(restored.url, 'https://example.com/img.png');
      expect(restored.x, closeTo(400, 1e-9));
      expect(restored.y, closeTo(800, 1e-9));
      expect(restored.width, closeTo(1200, 1e-9));
      expect(restored.height, closeTo(800, 1e-9));
    });

    test('legacy 0..1 image coords migrate to legacy-4096 space', () {
      // Same rationale as the stroke-point test: legacy normalised
      // values rescale by 4096 (not 100k) so old persisted images keep
      // their relative positions in the top-left of the new space.
      const legacyExtent = 4096.0;
      final restored = CanvasImage.fromJson({
        'id': 'img-legacy',
        'url': 'https://example.com/old.png',
        'x': 0.1,
        'y': 0.2,
        'width': 0.5,
        'height': 0.25,
      });
      expect(restored.x, closeTo(legacyExtent * 0.1, 1e-9));
      expect(restored.y, closeTo(legacyExtent * 0.2, 1e-9));
      expect(restored.width, closeTo(legacyExtent * 0.5, 1e-9));
      expect(restored.height, closeTo(legacyExtent * 0.25, 1e-9));
    });

    test('copyWith updates only specified fields', () {
      const img = CanvasImage(
        id: 'img-2',
        url: 'https://example.com/foo.png',
        x: 0,
        y: 0,
        width: 800,
        height: 400,
      );
      final moved = img.copyWith(x: 2048, y: 2456);
      expect(moved.id, 'img-2');
      expect(moved.url, 'https://example.com/foo.png');
      expect(moved.x, closeTo(2048, 1e-9));
      expect(moved.y, closeTo(2456, 1e-9));
      // Unchanged
      expect(moved.width, closeTo(800, 1e-9));
      expect(moved.height, closeTo(400, 1e-9));
    });
  });

  group('AvatarPosition', () {
    test('copyWith updates canvas-space coordinates', () {
      const pos = AvatarPosition(userId: 'u1', x: 2048, y: 2048);
      final moved = pos.copyWith(x: 3000, y: 500);
      expect(moved.userId, 'u1');
      expect(moved.x, closeTo(3000, 1e-9));
      expect(moved.y, closeTo(500, 1e-9));
    });
  });

  group('CanvasState', () {
    test('default state is empty and not loaded', () {
      const state = CanvasState();
      expect(state.strokes, isEmpty);
      expect(state.images, isEmpty);
      expect(state.avatarPositions, isEmpty);
      expect(state.activePoints, isEmpty);
      expect(state.selectedTool, CanvasTool.none);
      expect(state.isLoaded, isFalse);
    });

    test('copyWith replaces only given fields', () {
      const state = CanvasState();
      final updated = state.copyWith(
        isLoaded: true,
        selectedTool: CanvasTool.eraser,
        currentColor: const Color(0xFFFF0000),
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
      final stroke = const CanvasStroke(
        id: 's1',
        color: '#00FF00',
        width: 3.0,
        points: [CanvasPoint(x: 0.0, y: 0.0)],
      );
      final updated = state.copyWith(strokes: [stroke]);
      expect(updated.strokes.length, 1);
      expect(updated.strokes.first.id, 's1');
    });
  });
}
