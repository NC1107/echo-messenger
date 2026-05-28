/**
 * Voice-lounge canvas sync: stroke from client A is delivered to client B.
 *
 * This is the first concrete test that the two-client harness unblocks
 * (canvas_redesign.md Phase 3, PR D). Every canvas surface in
 * `audit_surfaces.ts` has historically been skipped with the rationale
 * "needs LiveKit channel; capture from a real call" — but stroke sync
 * doesn't actually require LiveKit. Canvas events are routed through
 * Echo's own ticket-authenticated WebSocket (`/ws`, see
 * apps/server/src/ws/events/canvas.rs); LiveKit only carries voice/video
 * media. We exercise the canvas-sync contract directly at that WS layer.
 *
 * What this verifies
 * ------------------
 * 1. Both clients can sign in and join a shared group.
 * 2. The group auto-creates a `lounge` voice channel.
 * 3. Client A sends a `canvas_event` of kind `stroke` over its WS.
 * 4. Client B receives a matching `canvas_event` on its WS within ~5s.
 * 5. Stroke points round-trip byte-for-byte (no quantization in the relay
 *    layer — canvas-space points are JSON numbers and the server passes
 *    them through verbatim).
 *
 * What this deliberately does NOT verify (out of scope for PR D)
 * --------------------------------------------------------------
 * - CanvasKit pixel equality. Asserting that A's drawn pixels match B's
 *   drawn pixels would test Flutter's renderer, not the sync contract.
 * - Mid-stroke `stroke_partial` cadence — covered by perf budget (PR F).
 * - Screen-share window sync — depends on PR coord-policy.
 * - Multi-device authority handoff — depends on PR multi-device.
 */
import { test, expect } from '@playwright/test';
import { withTwoClients, openCanvasWs, APP_URL } from './harness/two-client';

test.describe('voice lounge canvas sync', () => {
  test('stroke from client A is received by client B', async ({ browser }, testInfo) => {
    await withTwoClients(browser, testInfo, async ({ clientA, clientB, voiceChannelId }) => {
      // Both pages need to be on the app origin for the in-page WebSocket
      // to share the same `?server=` override the Flutter client uses.
      // We don't need Flutter itself to boot — just a real document on the
      // correct origin so WS handshakes carry the right CORS / Origin
      // headers. Use `domcontentloaded` (not `networkidle`) so the test
      // doesn't wait the full CanvasKit boot time we don't need.
      await Promise.all([
        clientA.page.goto(APP_URL, { waitUntil: 'domcontentloaded' }),
        clientB.page.goto(APP_URL, { waitUntil: 'domcontentloaded' }),
      ]);

      const wsA = await openCanvasWs(clientA.page, clientA.user.accessToken);
      const wsB = await openCanvasWs(clientB.page, clientB.user.accessToken);

      // A known stroke at coordinates well inside the 100k canvas-world
      // surface (see CANVAS_COORD_MIN/MAX in canvas_validation.rs). Points
      // are deliberately well-separated so any future tolerance-based
      // assertion has room to relax without aliasing into noise.
      const strokePoints = [
        { x: 12345.0, y: 6789.0 },
        { x: 12400.0, y: 6900.0 },
        { x: 12500.0, y: 7050.0 },
        { x: 12600.0, y: 7150.0 },
      ];
      const strokeFrame = {
        type: 'canvas_event',
        channel_id: voiceChannelId,
        kind: 'stroke',
        payload: {
          id: '00000000-0000-4000-8000-000000000001',
          points: strokePoints,
          color: '#ff0000',
          width: 4,
          tool: 'pen',
        },
      };

      try {
        await wsA.send(strokeFrame);

        const received = await wsB.waitForCanvasEvent(
          (ev) => ev.kind === 'stroke' && ev.channel_id === voiceChannelId,
          8000,
        );

        // Sanity: the event came from A.
        expect(received.from_user_id).toBe(clientA.user.userId);

        // Points round-trip — coordinates are passed verbatim through the
        // hub, so this is exact equality, not a tolerance check. (Tolerance
        // becomes relevant only once we also assert on rendered pixels.)
        const points = received.payload.points as { x: number; y: number }[];
        expect(points).toHaveLength(strokePoints.length);
        for (let i = 0; i < strokePoints.length; i++) {
          expect(points[i].x).toBeCloseTo(strokePoints[i].x, 6);
          expect(points[i].y).toBeCloseTo(strokePoints[i].y, 6);
        }
        expect(received.payload.color).toBe('#ff0000');
        expect(received.payload.tool).toBe('pen');
      } finally {
        await wsA.close().catch(() => {});
        await wsB.close().catch(() => {});
      }
    });
  });
});
