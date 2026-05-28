import 'dart:collection';

/// Lightweight performance instrumentation for the voice-lounge canvas.
///
/// Two metrics are tracked independently:
///   - **Paint duration**: measured at the [_CanvasPainter] call site via
///     [recordPaintMs]. Maintained in a 60-second rolling window so p50/p99
///     reflect recent draw activity, not the whole session.
///   - **Send-event rate**: outbound `stroke_partial` events are counted per
///     second via [recordSendEvent]. A sliding set of per-second buckets gives
///     both the average rate and the p99 burst over the measurement window.
///
/// Overhead target: < 0.1 ms per call. Both paths use Dart's built-in
/// collections with no allocations on the hot path beyond the List.add.
///
/// All members are static so callers don't need a provider or DI — this is
/// intentionally a module-level registry, not a service object.
///
/// Phase 5 / PR F of canvas_redesign.md v2.
class CanvasPerf {
  CanvasPerf._();

  // ---------------------------------------------------------------------------
  // Paint-duration rolling window (60 seconds)
  // ---------------------------------------------------------------------------

  static const int _kWindowSeconds = 60;

  /// Timestamps (epoch ms) parallel to [_paintMs] for window pruning.
  static final Queue<int> _paintTs = Queue<int>();

  /// Paint durations (ms) in arrival order.
  static final Queue<double> _paintMs = Queue<double>();

  // ---------------------------------------------------------------------------
  // Send-event per-second bucket
  // ---------------------------------------------------------------------------

  /// Each entry: [epochSecond, count].  We keep at most [_kWindowSeconds]
  /// buckets so the queue never grows beyond 60 entries.
  static final Queue<_SecBucket> _sendBuckets = Queue<_SecBucket>();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Record a single paint call duration.  Called from [_CanvasPainter.paint]
  /// after each frame.  [ms] should be the wall-clock milliseconds elapsed
  /// for the paint() body.
  static void recordPaintMs(double ms) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _paintTs.addLast(now);
    _paintMs.addLast(ms);
    _pruneWindow(now);
  }

  /// Increment the outbound `stroke_partial` counter for the current second.
  /// Called from [_sendCanvasEvent] in canvas_provider.dart for every partial
  /// stroke broadcast.
  static void recordSendEvent() {
    final sec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_sendBuckets.isNotEmpty && _sendBuckets.last.sec == sec) {
      _sendBuckets.last.count++;
    } else {
      _sendBuckets.addLast(_SecBucket(sec));
      _pruneSendBuckets(sec);
    }
  }

  /// Returns a snapshot of the current performance metrics.
  ///
  /// Percentiles are computed by sorting the rolling window at read time —
  /// the window is at most 60 s × 60 fps = 3 600 entries so the sort is
  /// negligible in a diagnostics context.
  static CanvasPerfSnapshot snapshot() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pruneWindow(now);

    final paintP50 = _percentile(_paintMs.toList(), 0.50);
    final paintP99 = _percentile(_paintMs.toList(), 0.99);

    final sec = now ~/ 1000;
    _pruneSendBuckets(sec);

    double sendAvg = 0;
    double sendP99 = 0;
    if (_sendBuckets.isNotEmpty) {
      final counts = _sendBuckets.map((b) => b.count.toDouble()).toList();
      sendAvg = counts.reduce((a, b) => a + b) / counts.length;
      sendP99 = _percentile(counts, 0.99);
    }

    return CanvasPerfSnapshot(
      paintP50Ms: paintP50,
      paintP99Ms: paintP99,
      sendEventsPerSecAvg: sendAvg,
      sendEventsPerSecP99: sendP99,
    );
  }

  /// Resets all accumulated data.  Used in tests to ensure isolation between
  /// test cases.
  static void reset() {
    _paintTs.clear();
    _paintMs.clear();
    _sendBuckets.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static void _pruneWindow(int nowMs) {
    final cutoff = nowMs - _kWindowSeconds * 1000;
    while (_paintTs.isNotEmpty && _paintTs.first < cutoff) {
      _paintTs.removeFirst();
      _paintMs.removeFirst();
    }
  }

  static void _pruneSendBuckets(int currentSec) {
    final cutoff = currentSec - _kWindowSeconds;
    while (_sendBuckets.isNotEmpty && _sendBuckets.first.sec < cutoff) {
      _sendBuckets.removeFirst();
    }
  }

  /// Returns the [p]-th percentile (0.0–1.0) of [values], or 0.0 if empty.
  /// [values] is sorted in-place; callers should pass a copy.
  static double _percentile(List<double> values, double p) {
    if (values.isEmpty) return 0.0;
    values.sort();
    if (values.length == 1) return values[0];
    final idx = (p * (values.length - 1)).round();
    return values[idx];
  }
}

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Immutable snapshot of canvas perf metrics at a point in time.
class CanvasPerfSnapshot {
  /// Median paint duration over the last 60 s.
  final double paintP50Ms;

  /// 99th-percentile paint duration over the last 60 s.
  final double paintP99Ms;

  /// Mean outbound `stroke_partial` events/second over the last 60 s.
  final double sendEventsPerSecAvg;

  /// 99th-percentile outbound events/second over the last 60 s.
  final double sendEventsPerSecP99;

  const CanvasPerfSnapshot({
    required this.paintP50Ms,
    required this.paintP99Ms,
    required this.sendEventsPerSecAvg,
    required this.sendEventsPerSecP99,
  });

  @override
  String toString() {
    return 'paint p50=${paintP50Ms.toStringAsFixed(2)}ms '
        'p99=${paintP99Ms.toStringAsFixed(2)}ms '
        'send/s avg=${sendEventsPerSecAvg.toStringAsFixed(1)} '
        'p99=${sendEventsPerSecP99.toStringAsFixed(1)}';
  }
}

/// Mutable per-second event counter.  Package-private.
class _SecBucket {
  final int sec;
  int count;
  _SecBucket(this.sec) : count = 1;
}
