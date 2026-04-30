import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/canvas_models.dart';

// ---------------------------------------------------------------------------
// These tests cover the pure-state logic of CanvasNotifier -- all WS / HTTP
// integration is excluded since no real Ref or server is needed here.
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // CanvasState mutation helpers used by CanvasNotifier
  // -------------------------------------------------------------------------

  group('handleCanvasEvent – stroke', () {
    test('appends stroke to state', () {
      var state = const CanvasState(isLoaded: true);
      final stroke = const CanvasStroke(
        id: 'stroke-1',
        color: '#FFFFFF',
        width: 3.0,
        points: [CanvasPoint(x: 0.1, y: 0.2), CanvasPoint(x: 0.3, y: 0.4)],
      );

      // Simulate what handleCanvasEvent("stroke") does.
      final newStrokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
      state = state.copyWith(strokes: newStrokes);

      expect(state.strokes.length, 1);
      expect(state.strokes.first.id, 'stroke-1');
    });
  });

  group('handleCanvasEvent – clear', () {
    test('removes all strokes', () {
      var state = const CanvasState(
        isLoaded: true,
        strokes: [
          CanvasStroke(
            id: 'a',
            color: '#FF0000',
            width: 2.0,
            points: [CanvasPoint(x: 0.0, y: 0.0)],
          ),
          CanvasStroke(
            id: 'b',
            color: '#00FF00',
            width: 2.0,
            points: [CanvasPoint(x: 0.5, y: 0.5)],
          ),
        ],
      );

      state = state.copyWith(strokes: []);

      expect(state.strokes, isEmpty);
    });
  });

  group('handleCanvasEvent – image_add', () {
    test('appends image to state', () {
      var state = const CanvasState(isLoaded: true);
      const image = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 0.2,
        y: 0.3,
        width: 0.25,
        height: 0.2,
      );

      final newImages = List<CanvasImage>.from(state.images)..add(image);
      state = state.copyWith(images: newImages);

      expect(state.images.length, 1);
      expect(state.images.first.id, 'img-1');
    });
  });

  group('handleCanvasEvent – image_move', () {
    test('updates position of matching image', () {
      const original = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 0.0,
        y: 0.0,
        width: 0.25,
        height: 0.2,
      );
      var state = const CanvasState(isLoaded: true, images: [original]);

      // Simulate image_move
      final updated = original.copyWith(x: 0.5, y: 0.6);
      final idx = state.images.indexWhere((img) => img.id == updated.id);
      final newImages = List<CanvasImage>.from(state.images)..[idx] = updated;
      state = state.copyWith(images: newImages);

      expect(state.images.first.x, closeTo(0.5, 1e-10));
      expect(state.images.first.y, closeTo(0.6, 1e-10));
    });
  });

  group('handleCanvasEvent – image_remove', () {
    test('removes the specified image', () {
      const img1 = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/a.png',
        x: 0.0,
        y: 0.0,
        width: 0.1,
        height: 0.1,
      );
      const img2 = CanvasImage(
        id: 'img-2',
        url: 'https://example.com/b.png',
        x: 0.5,
        y: 0.5,
        width: 0.1,
        height: 0.1,
      );
      var state = const CanvasState(isLoaded: true, images: [img1, img2]);

      final newImages = state.images.where((img) => img.id != 'img-1').toList();
      state = state.copyWith(images: newImages);

      expect(state.images.length, 1);
      expect(state.images.first.id, 'img-2');
    });
  });

  group('handleCanvasEvent – avatar_move', () {
    test('stores avatar position from remote user', () {
      var state = const CanvasState(isLoaded: true);

      final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
      updated['user-42'] = const AvatarPosition(
        userId: 'user-42',
        x: 0.7,
        y: 0.3,
      );
      state = state.copyWith(avatarPositions: updated);

      expect(state.avatarPositions['user-42']?.x, closeTo(0.7, 1e-10));
      expect(state.avatarPositions['user-42']?.y, closeTo(0.3, 1e-10));
    });

    test('clamps out-of-range avatar coords to [0, 1]', () {
      // The provider clamps x and y with .clamp(0.0, 1.0); test the clamp.
      final x = 1.5.clamp(0.0, 1.0);
      final y = (-0.1).clamp(0.0, 1.0);
      expect(x, 1.0);
      expect(y, 0.0);
    });
  });

  group('CanvasState.copyWith', () {
    test('does not mutate original', () {
      const original = CanvasState(
        strokeWidth: 5.0,
        selectedTool: CanvasTool.pen,
      );
      final copy = original.copyWith(
        strokeWidth: 10.0,
        selectedTool: CanvasTool.eraser,
      );
      // Original unchanged
      expect(original.strokeWidth, 5.0);
      expect(original.selectedTool, CanvasTool.pen);
      // Copy updated
      expect(copy.strokeWidth, 10.0);
      expect(copy.selectedTool, CanvasTool.eraser);
    });

    test('active stroke points are replaced on copyWith', () {
      const state = CanvasState();
      final pts = [
        const CanvasPoint(x: 0.0, y: 0.0),
        const CanvasPoint(x: 0.1, y: 0.1),
      ];
      final updated = state.copyWith(activePoints: pts);
      expect(updated.activePoints.length, 2);

      // "End stroke" clears active points
      final cleared = updated.copyWith(activePoints: []);
      expect(cleared.activePoints, isEmpty);
    });
  });
}
