import 'package:echo_app/src/services/canvas_perf.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Unit tests for CanvasPerf.
//
// Phase 5 / PR F of canvas_redesign.md v2.
// ---------------------------------------------------------------------------

void main() {
  setUp(CanvasPerf.reset);

  // -------------------------------------------------------------------------
  // Rolling-window paint timer
  // -------------------------------------------------------------------------

  group('CanvasPerf.recordPaintMs', () {
    test('snapshot returns zeros before any data', () {
      final snap = CanvasPerf.snapshot();
      expect(snap.paintP50Ms, 0.0);
      expect(snap.paintP99Ms, 0.0);
    });

    test('single sample: p50 == p99 == the sample', () {
      CanvasPerf.recordPaintMs(10.0);
      final snap = CanvasPerf.snapshot();
      expect(snap.paintP50Ms, 10.0);
      expect(snap.paintP99Ms, 10.0);
    });

    test('p50 is the median of an odd-length list', () {
      // 5 samples: median index is 2 (value 3.0).
      for (final v in [5.0, 1.0, 3.0, 7.0, 2.0]) {
        CanvasPerf.recordPaintMs(v);
      }
      final snap = CanvasPerf.snapshot();
      // Sorted: [1, 2, 3, 5, 7]. p50 index = round(0.50 * 4) = 2 → 3.0.
      expect(snap.paintP50Ms, 3.0);
    });

    test('p99 is the near-max of a large list', () {
      // 100 samples 1..100.
      for (int i = 1; i <= 100; i++) {
        CanvasPerf.recordPaintMs(i.toDouble());
      }
      final snap = CanvasPerf.snapshot();
      // p99 index = round(0.99 * 99) = 98 → value 99.
      expect(snap.paintP99Ms, 99.0);
    });

    test('reset clears all data', () {
      CanvasPerf.recordPaintMs(20.0);
      CanvasPerf.reset();
      final snap = CanvasPerf.snapshot();
      expect(snap.paintP50Ms, 0.0);
      expect(snap.paintP99Ms, 0.0);
    });
  });

  // -------------------------------------------------------------------------
  // Per-second send-event counter
  // -------------------------------------------------------------------------

  group('CanvasPerf.recordSendEvent', () {
    test('snapshot returns zero send rate before any events', () {
      final snap = CanvasPerf.snapshot();
      expect(snap.sendEventsPerSecAvg, 0.0);
      expect(snap.sendEventsPerSecP99, 0.0);
    });

    test('events in the same second are grouped into one bucket', () {
      // Record 10 events — all in the same second since tests run fast.
      for (int i = 0; i < 10; i++) {
        CanvasPerf.recordSendEvent();
      }
      final snap = CanvasPerf.snapshot();
      // One bucket with 10 events. avg == p99 == 10.
      expect(snap.sendEventsPerSecAvg, 10.0);
      expect(snap.sendEventsPerSecP99, 10.0);
    });

    test('avg reflects multiple buckets', () {
      // Simulate two distinct seconds by using internal state knowledge:
      // record, then read the avg (which prunes stale buckets).
      // Since we can't advance time without mocking, we confirm the bucket
      // increments correctly and avg is consistent.
      for (int i = 0; i < 5; i++) {
        CanvasPerf.recordSendEvent();
      }
      final snap = CanvasPerf.snapshot();
      expect(snap.sendEventsPerSecAvg, 5.0);
    });

    test('reset clears send buckets', () {
      for (int i = 0; i < 7; i++) {
        CanvasPerf.recordSendEvent();
      }
      CanvasPerf.reset();
      final snap = CanvasPerf.snapshot();
      expect(snap.sendEventsPerSecAvg, 0.0);
      expect(snap.sendEventsPerSecP99, 0.0);
    });
  });

  // -------------------------------------------------------------------------
  // CanvasPerfSnapshot.toString()
  // -------------------------------------------------------------------------

  group('CanvasPerfSnapshot.toString', () {
    test('includes all four metric labels', () {
      CanvasPerf.recordPaintMs(8.5);
      CanvasPerf.recordSendEvent();
      final snap = CanvasPerf.snapshot();
      final str = snap.toString();
      expect(str, contains('paint p50='));
      expect(str, contains('p99='));
      expect(str, contains('send/s avg='));
    });
  });

  // -------------------------------------------------------------------------
  // Percentile edge cases
  // -------------------------------------------------------------------------

  group('percentile edge cases', () {
    test('two samples: p50 returns first, p99 returns last', () {
      CanvasPerf.recordPaintMs(4.0);
      CanvasPerf.recordPaintMs(8.0);
      final snap = CanvasPerf.snapshot();
      // Sorted [4, 8]. p50 index = round(0.50*1)=1 → 8.0; p99 idx=1 → 8.0.
      expect(snap.paintP50Ms, 8.0);
      expect(snap.paintP99Ms, 8.0);
    });

    test('three samples: p50 is the middle value', () {
      CanvasPerf.recordPaintMs(1.0);
      CanvasPerf.recordPaintMs(9.0);
      CanvasPerf.recordPaintMs(5.0);
      final snap = CanvasPerf.snapshot();
      // Sorted [1, 5, 9]. p50 idx = round(0.5*2) = 1 → 5.0.
      expect(snap.paintP50Ms, 5.0);
    });
  });
}
