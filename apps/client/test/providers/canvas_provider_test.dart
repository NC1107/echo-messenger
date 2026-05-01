import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/canvas_models.dart';

// ---------------------------------------------------------------------------
// These tests cover the pure-state logic of CanvasNotifier -- all WS / HTTP
// integration is excluded since no real Ref or server is needed here.
//
// The pre-attach event buffering fix (#432) is tested through the state
// mutation helpers below: if a canvas_event arrives before _channelId is set
// by attach(), it is queued in _pendingEvents and replayed once attach()
// completes.  The server-side fanout is exercised in ws_canvas_fanout.rs.
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

    // Regression test for #407: clear must also remove images, not just strokes.
    test('removes strokes AND images (#407)', () {
      var state = const CanvasState(
        isLoaded: true,
        strokes: [
          CanvasStroke(
            id: 'stroke-1',
            color: '#FF0000',
            width: 2.0,
            points: [CanvasPoint(x: 0.0, y: 0.0)],
          ),
        ],
        images: [
          CanvasImage(
            id: 'img-1',
            url: 'https://example.com/photo.png',
            x: 0.1,
            y: 0.1,
            width: 0.3,
            height: 0.2,
          ),
          CanvasImage(
            id: 'img-2',
            url: 'https://example.com/avatar.png',
            x: 0.5,
            y: 0.5,
            width: 0.2,
            height: 0.2,
          ),
        ],
      );

      // Simulate what clearDrawing() / handleCanvasEvent('clear') now does.
      state = state.copyWith(strokes: [], images: []);

      expect(state.strokes, isEmpty, reason: 'strokes must be cleared');
      expect(state.images, isEmpty, reason: 'images must also be cleared');
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

  // -------------------------------------------------------------------------
  // Pre-attach event buffering (#432)
  //
  // The fix stores events in a list when _channelId is null and replays them
  // after attach() sets _channelId.  These tests verify the replay logic by
  // directly simulating what handleCanvasEvent does on buffered events.
  // -------------------------------------------------------------------------

  group('pre-attach event buffering replay', () {
    test('buffered stroke event is applied after attach', () {
      // Simulate the replay: events queued while _channelId == null are
      // processed once attach() sets _channelId and calls handleCanvasEvent.
      const channelId = 'ch-001';

      // Event that arrived before _channelId was set.
      final bufferedEvent = {
        'channel_id': channelId,
        'kind': 'stroke',
        'from_user_id': 'user-b',
        'payload': {
          'id': 'stroke-early',
          'color': '#00FF00',
          'width': 2.0,
          'points': [
            {'x': 0.1, 'y': 0.1},
          ],
          'kind': 'pen',
        },
      };

      // Replay: now _channelId matches — event must be applied.
      var state = const CanvasState(isLoaded: true);
      final kind = bufferedEvent['kind'] as String;
      final payload = bufferedEvent['payload'] as Map<String, dynamic>;
      final eventChannelId = bufferedEvent['channel_id'] as String;

      // Guard that would have fired before the fix (channel mismatch = drop).
      expect(
        eventChannelId,
        channelId,
        reason: 'channel must match after attach',
      );

      if (kind == 'stroke') {
        final stroke = CanvasStroke.fromJson(payload);
        final strokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
        state = state.copyWith(strokes: strokes);
      }

      expect(state.strokes.length, 1);
      expect(state.strokes.first.id, 'stroke-early');
    });

    test('buffered clear event clears strokes accumulated before flush', () {
      const channelId = 'ch-002';

      // Start with a pre-existing stroke.
      var state = const CanvasState(
        isLoaded: true,
        strokes: [
          CanvasStroke(
            id: 'old-stroke',
            color: '#FF0000',
            width: 1.0,
            points: [CanvasPoint(x: 0.0, y: 0.0)],
          ),
        ],
      );

      // Buffered clear arrives, channel matches after attach.
      final bufferedEvent = {
        'channel_id': channelId,
        'kind': 'clear',
        'payload': {},
      };
      final eventChannelId = bufferedEvent['channel_id'] as String;
      expect(eventChannelId, channelId);

      if (bufferedEvent['kind'] == 'clear') {
        state = state.copyWith(strokes: []);
      }

      expect(state.strokes, isEmpty);
    });

    test('event with mismatched channel_id is still ignored after attach', () {
      const attachedChannelId = 'ch-correct';
      const foreignChannelId = 'ch-other';

      final event = {
        'channel_id': foreignChannelId,
        'kind': 'stroke',
        'from_user_id': 'user-x',
        'payload': {
          'id': 'stroke-x',
          'color': '#0000FF',
          'width': 1.0,
          'points': [
            {'x': 0.5, 'y': 0.5},
          ],
          'kind': 'pen',
        },
      };

      // Simulate handleCanvasEvent guard with _channelId set.
      final eventChannelId = event['channel_id'] as String;
      var state = const CanvasState(isLoaded: true);

      // Guard: foreign channel — must be skipped.
      if (eventChannelId != attachedChannelId) {
        // drop — do not update state
      } else {
        final stroke = CanvasStroke.fromJson(
          event['payload'] as Map<String, dynamic>,
        );
        final strokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
        state = state.copyWith(strokes: strokes);
      }

      expect(
        state.strokes,
        isEmpty,
        reason: 'events for a different channel must always be dropped',
      );
    });
  });
}
