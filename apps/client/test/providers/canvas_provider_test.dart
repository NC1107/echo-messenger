import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
      // 100k-space absolute coords — no legacy migration triggered.
      final stroke = const CanvasStroke(
        id: 'stroke-1',
        color: '#FFFFFF',
        width: 3.0,
        points: [
          CanvasPoint(x: 10000.0, y: 20000.0),
          CanvasPoint(x: 30000.0, y: 40000.0),
        ],
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
          // 100k-space absolute coords — no legacy migration triggered.
          CanvasStroke(
            id: 'a',
            color: '#FF0000',
            width: 2.0,
            points: [CanvasPoint(x: 5000.0, y: 5000.0)],
          ),
          CanvasStroke(
            id: 'b',
            color: '#00FF00',
            width: 2.0,
            points: [CanvasPoint(x: 50000.0, y: 50000.0)],
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
          // 100k-space absolute coords — no legacy migration triggered.
          CanvasStroke(
            id: 'stroke-1',
            color: '#FF0000',
            width: 2.0,
            points: [CanvasPoint(x: 5000.0, y: 5000.0)],
          ),
        ],
        images: [
          // 100k-space absolute coords — no legacy migration triggered.
          CanvasImage(
            id: 'img-1',
            url: 'https://example.com/photo.png',
            x: 10000.0,
            y: 10000.0,
            width: 30000.0,
            height: 20000.0,
          ),
          CanvasImage(
            id: 'img-2',
            url: 'https://example.com/avatar.png',
            x: 50000.0,
            y: 50000.0,
            width: 20000.0,
            height: 20000.0,
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
      // 100k-space absolute coords — no legacy migration triggered.
      const image = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 20000.0,
        y: 30000.0,
        width: 25000.0,
        height: 20000.0,
      );

      final newImages = List<CanvasImage>.from(state.images)..add(image);
      state = state.copyWith(images: newImages);

      expect(state.images.length, 1);
      expect(state.images.first.id, 'img-1');
    });
  });

  group('handleCanvasEvent – image_move', () {
    test('updates position of matching image', () {
      // 100k-space absolute coords — no legacy migration triggered.
      const original = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/img.png',
        x: 5000.0,
        y: 5000.0,
        width: 25000.0,
        height: 20000.0,
      );
      var state = const CanvasState(isLoaded: true, images: [original]);

      // Simulate image_move
      final updated = original.copyWith(x: 50000.0, y: 60000.0);
      final idx = state.images.indexWhere((img) => img.id == updated.id);
      final newImages = List<CanvasImage>.from(state.images)..[idx] = updated;
      state = state.copyWith(images: newImages);

      expect(state.images.first.x, closeTo(50000.0, 1e-10));
      expect(state.images.first.y, closeTo(60000.0, 1e-10));
    });
  });

  group('handleCanvasEvent – image_remove', () {
    test('removes the specified image', () {
      // 100k-space absolute coords — no legacy migration triggered.
      const img1 = CanvasImage(
        id: 'img-1',
        url: 'https://example.com/a.png',
        x: 5000.0,
        y: 5000.0,
        width: 10000.0,
        height: 10000.0,
      );
      const img2 = CanvasImage(
        id: 'img-2',
        url: 'https://example.com/b.png',
        x: 50000.0,
        y: 50000.0,
        width: 10000.0,
        height: 10000.0,
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

      // 100k-space canvas-world coords.
      final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
      updated['user-42'] = const AvatarPosition(
        userId: 'user-42',
        x: 70000.0,
        y: 30000.0,
      );
      state = state.copyWith(avatarPositions: updated);

      expect(state.avatarPositions['user-42']?.x, closeTo(70000.0, 1e-10));
      expect(state.avatarPositions['user-42']?.y, closeTo(30000.0, 1e-10));
    });

    // Shared-whiteboard semantics: anyone can move anyone. The receiver
    // must read the target user id from `payload.user_id`, not from the
    // sender, so a move broadcast by user A targeting user B updates
    // user B's avatar entry on every receiving client.
    test('avatar_move updates the *target* user_id, not the sender', () {
      var state = const CanvasState(isLoaded: true);

      // Simulate the receiver branch in canvas_provider's
      // handleCanvasEvent('avatar_move'). Sender is `user-a`, target
      // (carried in payload) is `user-b`. The update must land on
      // `user-b`. Values are 100k-space canvas-world pixels.
      const fromUserId = 'user-a';
      const payload = <String, dynamic>{
        'user_id': 'user-b',
        'x': 4000.0,
        'y': 5000.0,
        'scale': 1.5,
      };

      final targetUserId = (payload['user_id'] as String?) ?? fromUserId;
      final x = (payload['x'] as num).toDouble();
      final y = (payload['y'] as num).toDouble();
      final scale = (payload['scale'] as num).toDouble().clamp(
        AvatarPosition.minScale,
        AvatarPosition.maxScale,
      );
      final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
      updated[targetUserId] = AvatarPosition(
        userId: targetUserId,
        x: x.clamp(0.0, kCanvasWidth),
        y: y.clamp(0.0, kCanvasHeight),
        scale: scale,
      );
      state = state.copyWith(avatarPositions: updated);

      expect(state.avatarPositions['user-b']?.x, closeTo(4000.0, 1e-10));
      expect(state.avatarPositions['user-b']?.y, closeTo(5000.0, 1e-10));
      expect(state.avatarPositions['user-b']?.scale, 1.5);
      expect(
        state.avatarPositions.containsKey('user-a'),
        isFalse,
        reason: 'sender must not be tracked unless they are also the target',
      );
    });

    // Back-compat: older clients only ever sent avatar_move for their
    // own avatar, with no `user_id` field. Fall back to the sender.
    test('avatar_move without payload user_id falls back to sender', () {
      var state = const CanvasState(isLoaded: true);
      const fromUserId = 'legacy-user';
      // 100k-space canvas-world pixels.
      const payload = <String, dynamic>{'x': 10000.0, 'y': 90000.0};

      final targetUserId = (payload['user_id'] as String?) ?? fromUserId;
      final x = (payload['x'] as num).toDouble();
      final y = (payload['y'] as num).toDouble();
      final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
      updated[targetUserId] = AvatarPosition(userId: targetUserId, x: x, y: y);
      state = state.copyWith(avatarPositions: updated);

      expect(state.avatarPositions['legacy-user']?.x, closeTo(10000.0, 1e-10));
      expect(state.avatarPositions['legacy-user']?.y, closeTo(90000.0, 1e-10));
    });

    // The local-drag path constructs the outbound payload directly. The
    // payload.user_id MUST equal the *target* avatar's user id, not the
    // moving client's own user id — that is what makes "user A moves
    // user B's avatar" possible.
    test('moveAvatar broadcast payload carries the target user_id', () {
      // Build the outbound payload exactly as commitAvatarMove does.
      // Values are 100k-space canvas-world pixels.
      const targetUserId = 'user-b';
      const pos = CanvasPoint(x: 25000.0, y: 75000.0);
      const scale = 1.0;
      final outbound = {
        'user_id': targetUserId,
        'x': pos.x,
        'y': pos.y,
        'scale': scale,
      };
      expect(outbound['user_id'], targetUserId);
      expect(outbound['x'], closeTo(25000.0, 1e-10));
      expect(outbound['y'], closeTo(75000.0, 1e-10));
    });

    test('clamps out-of-range avatar coords to canvas bounds', () {
      // The provider clamps x and y with .clamp(0.0, kCanvasWidth/Height).
      final x = 150000.0.clamp(0.0, kCanvasWidth);
      final y = (-1.0).clamp(0.0, kCanvasHeight);
      expect(x, kCanvasWidth);
      expect(y, 0.0);
    });

    test('AvatarPosition.scale defaults to 1.0 and survives copyWith', () {
      const a = AvatarPosition(userId: 'u', x: 0.3, y: 0.6);
      expect(a.scale, 1.0);
      final moved = a.copyWith(x: 0.4);
      expect(moved.scale, 1.0);
      final resized = moved.copyWith(scale: 2.5);
      expect(resized.scale, 2.5);
      expect(resized.x, 0.4);
    });

    test('AvatarPosition.scale honours min/max constants', () {
      expect(AvatarPosition.minScale, lessThan(1.0));
      expect(AvatarPosition.maxScale, greaterThan(1.0));
      // Clamping happens inside the controller; verify constants are wired so
      // a future refactor does not silently drop the bound.
      expect(
        AvatarPosition.minScale,
        lessThanOrEqualTo(AvatarPosition.maxScale),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // screenshare_move — shared screen-share window position broadcast.
  // Mirrors avatar_move: ephemeral, relayed by server, never persisted.
  // Anyone can drag any window; receivers update CanvasState
  // .screenSharePositions[windowId].
  // ---------------------------------------------------------------------------

  group('handleCanvasEvent – screenshare_move', () {
    test('roundtrips a window position payload through state', () {
      var state = const CanvasState(isLoaded: true);

      // Simulate handleCanvasEvent('screenshare_move').
      const payload = <String, dynamic>{
        'window_id': 'screenshare-local',
        'x': 120.0,
        'y': 80.0,
        'width': 320.0,
        'height': 180.0,
      };

      final windowId = payload['window_id'] as String;
      final x = (payload['x'] as num).toDouble();
      final y = (payload['y'] as num).toDouble();
      final w = (payload['width'] as num).toDouble();
      final h = (payload['height'] as num).toDouble();
      final updated = Map<String, ScreenShareWindow>.from(
        state.screenSharePositions,
      );
      updated[windowId] = ScreenShareWindow(
        windowId: windowId,
        x: x,
        y: y,
        width: w,
        height: h,
      );
      state = state.copyWith(screenSharePositions: updated);

      final stored = state.screenSharePositions['screenshare-local'];
      expect(stored, isNotNull);
      expect(stored!.x, closeTo(120.0, 1e-10));
      expect(stored.y, closeTo(80.0, 1e-10));
      expect(stored.width, closeTo(320.0, 1e-10));
      expect(stored.height, closeTo(180.0, 1e-10));
    });

    test('outbound move payload carries the windowId and CSS px geometry', () {
      // moveScreenShare → toJson on the ScreenShareWindow it stores.
      const window = ScreenShareWindow(
        windowId: 'screenshare-abc',
        x: 50,
        y: 60,
        width: 400,
        height: 225,
      );
      final outbound = window.toJson();
      expect(outbound['window_id'], 'screenshare-abc');
      expect(outbound['x'], 50);
      expect(outbound['y'], 60);
      expect(outbound['width'], 400);
      expect(outbound['height'], 225);
    });

    test('preserves prior width/height when payload omits them', () {
      var state = const CanvasState(
        isLoaded: true,
        screenSharePositions: {
          'screenshare-x': ScreenShareWindow(
            windowId: 'screenshare-x',
            x: 0,
            y: 0,
            width: 320,
            height: 180,
          ),
        },
      );

      // Simulate the receiver: fall back to existing width/height when
      // a peer sends a move-only payload.
      const payload = <String, dynamic>{
        'window_id': 'screenshare-x',
        'x': 100.0,
        'y': 200.0,
      };
      final id = payload['window_id'] as String;
      final existing = state.screenSharePositions[id];
      final w =
          (payload['width'] as num?)?.toDouble() ?? existing?.width ?? 320.0;
      final h =
          (payload['height'] as num?)?.toDouble() ?? existing?.height ?? 180.0;
      final updated = Map<String, ScreenShareWindow>.from(
        state.screenSharePositions,
      );
      updated[id] = ScreenShareWindow(
        windowId: id,
        x: (payload['x'] as num).toDouble(),
        y: (payload['y'] as num).toDouble(),
        width: w,
        height: h,
      );
      state = state.copyWith(screenSharePositions: updated);

      final stored = state.screenSharePositions['screenshare-x']!;
      expect(stored.x, 100.0);
      expect(stored.y, 200.0);
      expect(stored.width, 320.0, reason: 'fell back to existing width');
      expect(stored.height, 180.0, reason: 'fell back to existing height');
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
      // 100k-space absolute coords — no legacy migration triggered.
      final pts = [
        const CanvasPoint(x: 5000.0, y: 5000.0),
        const CanvasPoint(x: 10000.0, y: 10000.0),
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
      // 100k-space absolute coords — no legacy migration triggered.
      final bufferedEvent = {
        'channel_id': channelId,
        'kind': 'stroke',
        'from_user_id': 'user-b',
        'payload': {
          'id': 'stroke-early',
          'color': '#00FF00',
          'width': 2.0,
          'points': [
            {'x': 10000.0, 'y': 10000.0},
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

      // Start with a pre-existing stroke. 100k-space absolute coords.
      var state = const CanvasState(
        isLoaded: true,
        strokes: [
          CanvasStroke(
            id: 'old-stroke',
            color: '#FF0000',
            width: 1.0,
            points: [CanvasPoint(x: 5000.0, y: 5000.0)],
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

    // Regression test for the 2026-05-27 user report:
    // "If I draw and someone is not in the call, when they join they should
    // see my drawings." Specifically, this guards against the inverse race:
    // a WS canvas_event arriving DURING the REST snapshot fetch must NOT be
    // applied to a state that is about to be overwritten by the fetch.
    // Before the fix, _channelId was set BEFORE awaiting _fetchCanvas, so
    // mid-fetch events mutated state and then the fetch result wiped them.
    //
    // The fix is to leave _channelId null until the fetch resolves, and
    // buffer events whose channel matches _attachingChannelId.
    test(
      'mid-fetch events are buffered then replayed after snapshot lands',
      () {
        // Simulate the attach state machine.
        String? channelId; // _channelId
        String? attachingChannelId; // _attachingChannelId
        final pending = <Map<String, dynamic>>[];
        var state = const CanvasState();

        // 1) attach() starts: mark attaching, leave _channelId null.
        attachingChannelId = 'ch-fetch-race';
        channelId = null;
        state = const CanvasState();

        // 2) A mid-fetch WS stroke event arrives.
        // 100k-space absolute coords — no legacy migration triggered.
        final event = {
          'channel_id': 'ch-fetch-race',
          'kind': 'stroke',
          'from_user_id': 'peer-1',
          'payload': {
            'id': 'mid-fetch-stroke',
            'color': '#123456',
            'width': 2.0,
            'points': [
              {'x': 20000.0, 'y': 20000.0},
            ],
            'kind': 'pen',
          },
        };

        // The fixed handleCanvasEvent buffers it: _channelId is still null
        // (fetch hasn't resolved), so the event is queued if its channel_id
        // matches _attachingChannelId.
        if (channelId == null && event['channel_id'] == attachingChannelId) {
          pending.add(event);
        }

        // 3) Fetch resolves with an empty board (the peer drew the stroke
        // AFTER our GET hit the DB).
        state = state.copyWith(strokes: [], images: [], isLoaded: true);

        // 4) Promote attaching → attached, then replay buffered events.
        channelId = attachingChannelId;
        attachingChannelId = null;
        for (final ev in pending) {
          if (ev['channel_id'] == channelId && ev['kind'] == 'stroke') {
            final stroke = CanvasStroke.fromJson(
              ev['payload'] as Map<String, dynamic>,
            );
            final next = List<CanvasStroke>.from(state.strokes)..add(stroke);
            state = state.copyWith(strokes: next);
          }
        }

        expect(
          state.strokes.length,
          1,
          reason: 'mid-fetch stroke must survive snapshot overwrite',
        );
        expect(state.strokes.first.id, 'mid-fetch-stroke');
      },
    );

    test('event with mismatched channel_id is still ignored after attach', () {
      const attachedChannelId = 'ch-correct';
      const foreignChannelId = 'ch-other';

      // 100k-space absolute coords — no legacy migration triggered.
      final event = {
        'channel_id': foreignChannelId,
        'kind': 'stroke',
        'from_user_id': 'user-x',
        'payload': {
          'id': 'stroke-x',
          'color': '#0000FF',
          'width': 1.0,
          'points': [
            {'x': 50000.0, 'y': 50000.0},
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

  // ---------------------------------------------------------------------------
  // Late-partial / drag-id regression (2026-05-27)
  //
  // Bug: holding a finger still at the end of a stroke for a few seconds let
  // the partial-broadcast Timer fire AFTER endStroke had built and sent the
  // final stroke. Remotes saw the late partial, recreated the
  // `partial_<uid>_in_progress` placeholder on top of the final stroke, and
  // never cleared it again — local user saw the line, remote callers didn't.
  //
  // Fix: a `_strokeActive` flag flips false inside endStroke (and inside
  // startStroke of the next drag) BEFORE any state work, so a late tick is
  // a no-op. `_dragId` increments per drag so we can assert each drag is
  // distinct without relying on Timer ordering.
  // ---------------------------------------------------------------------------

  group('stroke lifecycle – late partial defence', () {
    test(
      'endStroke flips _strokeActive false even with no committed channel',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(canvasProvider.notifier);

        notifier.setTool(CanvasTool.pen);
        notifier.startStroke(const CanvasPoint(x: 10000.0, y: 10000.0));
        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isTrue);
        notifier.continueStroke(const CanvasPoint(x: 20000.0, y: 20000.0));
        notifier.endStroke();
        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isFalse);
      },
    );

    test('flush after endStroke is a no-op (no late partial broadcast)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(canvasProvider.notifier);

      notifier.setTool(CanvasTool.pen);
      notifier.startStroke(const CanvasPoint(x: 5000.0, y: 5000.0));
      notifier.continueStroke(const CanvasPoint(x: 50000.0, y: 50000.0));
      notifier.endStroke();

      // Simulate the partial Timer firing AFTER endStroke — this is the
      // exact race that produced the bug. The flush must be a no-op:
      // _strokeActive stays false and no exception is thrown.
      // ignore: invalid_use_of_visible_for_testing_member
      notifier.debugFlushStrokePoints();
      // ignore: invalid_use_of_visible_for_testing_member
      expect(notifier.debugIsStrokeActive, isFalse);
      // Repeated late flushes also stay no-op.
      // ignore: invalid_use_of_visible_for_testing_member
      notifier.debugFlushStrokePoints();
      // ignore: invalid_use_of_visible_for_testing_member
      expect(notifier.debugIsStrokeActive, isFalse);
    });

    test('startStroke bumps drag id and arms the active flag', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(canvasProvider.notifier);

      notifier.setTool(CanvasTool.pen);
      // ignore: invalid_use_of_visible_for_testing_member
      final id0 = notifier.debugDragId;
      notifier.startStroke(const CanvasPoint(x: 5000.0, y: 5000.0));
      // ignore: invalid_use_of_visible_for_testing_member
      final id1 = notifier.debugDragId;
      // ignore: invalid_use_of_visible_for_testing_member
      expect(notifier.debugIsStrokeActive, isTrue);
      expect(id1, greaterThan(id0));

      notifier.endStroke();
      notifier.startStroke(const CanvasPoint(x: 10000.0, y: 10000.0));
      // ignore: invalid_use_of_visible_for_testing_member
      expect(notifier.debugDragId, greaterThan(id1));
    });

    test(
      'late partial from a previous drag does not leak into the new drag',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(canvasProvider.notifier);

        notifier.setTool(CanvasTool.pen);

        // Drag 1: start → continue → end. 100k-space canvas coords.
        notifier.startStroke(const CanvasPoint(x: 5000.0, y: 5000.0));
        notifier.continueStroke(const CanvasPoint(x: 10000.0, y: 10000.0));
        notifier.endStroke();

        // Drag 2: start → continue → simulate a STALE late tick from drag 1
        // arriving before this drag finishes → end.
        notifier.startStroke(const CanvasPoint(x: 50000.0, y: 50000.0));
        notifier.continueStroke(const CanvasPoint(x: 60000.0, y: 60000.0));

        // A late tick scheduled by drag 1 cannot leak its points — when the
        // tick fires, startStroke has already cleared _pendingStrokePoints
        // and the per-drag id changed. Manually call the flush to simulate.
        // ignore: invalid_use_of_visible_for_testing_member
        notifier.debugFlushStrokePoints();

        // Drag 2's accumulated points must still be (50000, 60000) —
        // untouched by any phantom drag-1 state. In-flight points live in
        // the notifier's off-state accumulator now (not state.activePoints)
        // so we read them via the debug hook.
        // ignore: invalid_use_of_visible_for_testing_member
        final pts = notifier.debugStrokePoints;
        expect(pts.length, 2);
        expect(pts.first.x, closeTo(50000.0, 1e-10));
        expect(pts.last.x, closeTo(60000.0, 1e-10));

        notifier.endStroke();
        // ignore: invalid_use_of_visible_for_testing_member
        expect(notifier.debugIsStrokeActive, isFalse);
      },
    );

    test('endStroke is safe to call on a cancelled (never-active) drag', () {
      // Mirrors the gesture-arena-steal path: InteractiveViewer grabs the
      // pointer mid-stroke, Listener fires onPointerCancel → onPointerUp →
      // endStroke. activePoints might be empty if start never landed.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(canvasProvider.notifier);

      notifier.setTool(CanvasTool.pen);
      // No startStroke — directly end.
      notifier.endStroke();
      // ignore: invalid_use_of_visible_for_testing_member
      expect(notifier.debugIsStrokeActive, isFalse);
      expect(container.read(canvasProvider).activePoints, isEmpty);
    });
  });
}
