import 'dart:ui' show Offset, Size;

import '../models/canvas_models.dart';

/// One historical position of a puck on the voice-lounge canvas.
class TrailSample {
  final CanvasPoint pos;
  final DateTime at;

  const TrailSample({required this.pos, required this.at});
}

/// One trail sample translated into pixel space, ready for the
/// painter.  [offset] is the pixel offset from the puck's *current*
/// position to the historical position.  [opacity] runs from ~1.0
/// just after the sample is recorded down to 0.0 at [PuckTrail.ttl].
class RenderedTrailSample {
  final Offset offset;
  final double opacity;

  const RenderedTrailSample({required this.offset, required this.opacity});
}

/// Bounded ring buffer of recent puck positions used to paint a
/// fading motion trail behind a draggable avatar in the voice lounge.
///
/// Pure Dart, no Flutter widget dependencies — unit-testable in
/// isolation.  Phase 3a sub-slice 2 of `docs/ux-roadmap.md`.
///
/// The class is package-public so the widget code in
/// `voice_canvas.dart` can compose it; it is not part of the app's
/// stable API surface.  Treat as implementation detail of the
/// voice lounge canvas.
class PuckTrail {
  /// Maximum number of historical samples retained.  Defaults to 6 —
  /// enough for a visible streak without overdrawing the canvas.
  final int maxSamples;

  /// How long a sample survives before it falls out of the trail.
  /// Defaults to 600 ms.
  final Duration ttl;

  /// Visible-for-testing accessor for the underlying buffer.  Do not
  /// mutate.
  List<TrailSample> get samples => List.unmodifiable(_samples);

  final List<TrailSample> _samples = [];

  PuckTrail({this.maxSamples = 6, this.ttl = const Duration(milliseconds: 600)})
    : assert(maxSamples > 0),
      assert(ttl > Duration.zero);

  /// True when no samples are present.  When this flips true the
  /// owning widget should stop its repaint ticker.
  bool get isEmpty => _samples.isEmpty;

  /// Record a new historical position.  If the buffer is full the
  /// oldest sample is dropped.
  void addSample(CanvasPoint pos, DateTime now) {
    _samples.add(TrailSample(pos: pos, at: now));
    if (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }

  /// Drop samples older than [ttl] relative to [now].  Call from the
  /// ticker callback so an idle puck's trail decays naturally.
  void prune(DateTime now) {
    _samples.removeWhere((s) => now.difference(s.at) >= ttl);
  }

  /// Translate the buffered samples into pixel-space rendering data.
  ///
  /// [current] is the puck's current normalized position; the
  /// returned offsets are relative to that point so the painter can
  /// draw at `Center + offset`.  [canvasSize] converts normalized
  /// units back to pixels.
  ///
  /// Samples older than [ttl] are filtered out (without mutating the
  /// buffer — call [prune] separately to evict them).
  List<RenderedTrailSample> render({
    required CanvasPoint current,
    required Size canvasSize,
    required DateTime now,
  }) {
    if (_samples.isEmpty) return const [];
    final ttlMs = ttl.inMilliseconds;
    final out = <RenderedTrailSample>[];
    for (final s in _samples) {
      final ageMs = now.difference(s.at).inMilliseconds;
      if (ageMs >= ttlMs) continue;
      // Linear fade.  Older samples vanish first.
      final opacity = (1.0 - ageMs / ttlMs).clamp(0.0, 1.0);
      final dx = (s.pos.x - current.x) * canvasSize.width;
      final dy = (s.pos.y - current.y) * canvasSize.height;
      out.add(RenderedTrailSample(offset: Offset(dx, dy), opacity: opacity));
    }
    return out;
  }

  /// Drop all buffered samples.  Used when reduce-motion is enabled
  /// or when the widget is being disposed.
  void clear() => _samples.clear();
}
