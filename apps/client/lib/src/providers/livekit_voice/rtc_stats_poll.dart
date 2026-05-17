import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:livekit_client/livekit_client.dart';

/// Sample emitted by [RtcStatsPoll] on each tick: outbound audio bitrate in
/// bits per second and round-trip-time in milliseconds.
///
/// Both fields default to `0` before the first valid sample arrives — UI
/// consumers should treat `0` as "no signal yet" rather than literally zero.
@immutable
class RtcStatsSample {
  final int audioBitrateBps;
  final double rttMs;

  const RtcStatsSample({required this.audioBitrateBps, required this.rttMs});

  static const empty = RtcStatsSample(audioBitrateBps: 0, rttMs: 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RtcStatsSample &&
          other.audioBitrateBps == audioBitrateBps &&
          other.rttMs == rttMs);

  @override
  int get hashCode => Object.hash(audioBitrateBps, rttMs);
}

/// Periodically scrapes the LiveKit peer connections' `getStats()` for
/// outbound audio bitrate and the selected candidate pair's RTT, and
/// surfaces them through a [ValueNotifier].
///
/// The bitrate is computed as a delta of `bytesSent` between successive
/// ticks against the wall-clock delta of the report timestamps — a single
/// snapshot of `bytesSent` is meaningless on its own. RTT is read directly
/// from the `candidate-pair` report (seconds → ms).
///
/// Wired into [LiveKitVoiceNotifier.joinChannel]; the voice dock reads the
/// resulting state fields and surfaces them in the connection-quality
/// tooltip (#937, follow-up to #906).
class RtcStatsPoll {
  /// How often to fetch a fresh `getStats()` snapshot.  Two seconds keeps
  /// the dock tooltip live without taxing the WebRTC stack.
  static const Duration pollInterval = Duration(seconds: 2);

  final Room _room;
  final void Function(RtcStatsSample sample)? onSample;

  final ValueNotifier<RtcStatsSample> sample = ValueNotifier<RtcStatsSample>(
    RtcStatsSample.empty,
  );

  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;

  // Track the previous outbound-rtp audio bytesSent + timestamp so we can
  // compute a per-tick delta.  Keyed by stats-report id so a republished
  // track (which gets a fresh id) doesn't accidentally subtract from the
  // wrong baseline and produce a wild bitrate spike.
  final Map<String, _BytesSample> _prevBytes = <String, _BytesSample>{};

  RtcStatsPoll(this._room, {this.onSample});

  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
    sample.dispose();
  }

  Future<void> _tick() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    try {
      final pcs = _peerConnections();
      if (pcs.isEmpty) return;

      var totalBitrate = 0;
      var rttMs = 0.0;
      var sawRtt = false;
      // Track which outbound-rtp report ids appear this tick so stale entries
      // (e.g. from a track that was unpublished) can be pruned from _prevBytes.
      final currentIds = <String>{};

      for (final pc in pcs) {
        final List<StatsReport> reports;
        try {
          reports = await pc.getStats();
        } catch (_) {
          // getStats may throw mid-disconnect — skip this peer this tick.
          continue;
        }
        if (_disposed) return;

        totalBitrate += _collectAudioBitrate(reports, currentIds);

        final pcRtt = _collectRtt(reports);
        if (pcRtt != null) {
          rttMs = pcRtt;
          sawRtt = true;
        }
      }

      _pruneStaleBytes(currentIds);

      if (_disposed) return;
      final next = RtcStatsSample(
        audioBitrateBps: totalBitrate,
        rttMs: sawRtt ? rttMs : sample.value.rttMs,
      );
      if (next != sample.value) {
        sample.value = next;
        onSample?.call(next);
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Iterates [reports] for `outbound-rtp` audio entries, accumulates the
  /// per-tick bitrate delta, records the current snapshot into [_prevBytes],
  /// and registers each seen report id in [currentIds].
  ///
  /// Returns the total audio bitrate in bits-per-second contributed by all
  /// outbound audio senders found in this report set.
  int _collectAudioBitrate(List<StatsReport> reports, Set<String> currentIds) {
    var bitrate = 0;
    for (final r in reports) {
      if (r.type != 'outbound-rtp') continue;
      final kind = r.values['kind'] ?? r.values['mediaType'];
      if (kind != 'audio') continue;

      final bytesSent = r.values['bytesSent'];
      if (bytesSent is! num) continue;
      final tsMs = r.timestamp;

      currentIds.add(r.id);
      final prev = _prevBytes[r.id];
      _prevBytes[r.id] = _BytesSample(bytesSent.toInt(), tsMs);

      if (prev == null) continue;
      final deltaBytes = bytesSent.toInt() - prev.bytes;
      final deltaMs = tsMs - prev.timestampMs;
      if (deltaBytes <= 0 || deltaMs <= 0) continue;

      // bits / sec = bytes * 8 / (ms / 1000)
      final bps = (deltaBytes * 8 * 1000) / deltaMs;
      bitrate += bps.round();
    }
    return bitrate;
  }

  /// Extracts the round-trip time in milliseconds from [reports] by locating
  /// the selected `candidate-pair` via a `transport` report, falling back to
  /// any pair flagged `selected` or `nominated`.
  ///
  /// Returns `null` when no usable RTT value is present in the report set.
  double? _collectRtt(List<StatsReport> reports) {
    // First pass: resolve the selected candidate-pair id via the transport
    // report, and collect all candidate-pair entries for lookup.
    String? selectedPairId;
    final candidatePairs = <String, StatsReport>{};
    for (final r in reports) {
      if (r.type == 'transport') {
        final id = r.values['selectedCandidatePairId'];
        if (id is String && id.isNotEmpty) selectedPairId = id;
      } else if (r.type == 'candidate-pair') {
        candidatePairs[r.id] = r;
      }
    }

    // Fallback: candidate-pair flagged `selected` or `nominated`.
    if (selectedPairId == null || !candidatePairs.containsKey(selectedPairId)) {
      selectedPairId = _findNominatedPairId(candidatePairs);
    }

    if (selectedPairId == null) return null;
    final rttSec =
        candidatePairs[selectedPairId]?.values['currentRoundTripTime'];
    if (rttSec is! num) return null;
    return rttSec.toDouble() * 1000.0;
  }

  /// Scans [candidatePairs] for the first entry flagged `selected` or
  /// `nominated` and returns its id, or `null` if none is found.
  String? _findNominatedPairId(Map<String, StatsReport> candidatePairs) {
    for (final entry in candidatePairs.entries) {
      final v = entry.value.values;
      if (v['selected'] == true || v['nominated'] == true) return entry.key;
    }
    return null;
  }

  /// Removes entries from [_prevBytes] whose ids are not present in
  /// [currentIds] — avoids unbounded growth when tracks are unpublished.
  void _pruneStaleBytes(Set<String> currentIds) {
    _prevBytes.removeWhere((id, _) => !currentIds.contains(id));
  }

  /// Pull the publisher + subscriber peer-connections off the LiveKit room.
  /// Returns an empty list if the engine has torn them down (e.g. during a
  /// reconnect) — the next tick will pick them back up.
  List<dynamic> _peerConnections() {
    final pcs = <dynamic>[];
    try {
      final engine = (_room as dynamic).engine;
      final publisher = engine?.publisher;
      final subscriber = engine?.subscriber;
      final publisherPc = publisher?.pc;
      final subscriberPc = subscriber?.pc;
      if (publisherPc != null) pcs.add(publisherPc);
      if (subscriberPc != null) pcs.add(subscriberPc);
    } catch (_) {
      // LiveKit engine internals are not part of the public API surface;
      // swallow and let the next tick retry rather than killing the timer.
    }
    return pcs;
  }
}

class _BytesSample {
  final int bytes;
  final double timestampMs;
  const _BytesSample(this.bytes, this.timestampMs);
}
