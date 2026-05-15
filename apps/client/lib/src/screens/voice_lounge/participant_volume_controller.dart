/// Per-participant playback volume control for the voice lounge.
///
/// LiveKit's Dart SDK at 2.7.0 does not expose `RemoteParticipant.setVolume`
/// directly, so this helper iterates the participant's audio publications and
/// adjusts the underlying [rtc.MediaStreamTrack] gain via the WebRTC
/// `Helper.setVolume` API. The effect is purely local — only this client's
/// playback level changes; the remote participant and other peers are
/// unaffected.
///
/// Volumes are tracked in an in-memory `Map<identity, volume>` keyed by the
/// remote participant identity (NOT sid, so the value sticks across
/// reconnects within the same lounge session). Persistence across app
/// restarts is intentionally out of scope (beta).
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// In-memory store of per-identity playback volumes (0.0 - 1.0).
///
/// Singleton-style: there's a single lounge session at a time. Values default
/// to 1.0 (100%) when a peer is absent from the map.
class ParticipantVolumeController {
  ParticipantVolumeController._();

  static final ParticipantVolumeController instance =
      ParticipantVolumeController._();

  final Map<String, double> _volumes = {};

  /// Returns the stored volume for [identity], or 1.0 if none is set.
  double volumeFor(String identity) => _volumes[identity] ?? 1.0;

  /// Persists [volume] (clamped to 0..1) for [identity] and applies it to
  /// every currently-subscribed audio track on [participant].
  ///
  /// Safe to call repeatedly while the user drags the slider; the underlying
  /// `Helper.setVolume` call is fire-and-forget per track.
  Future<void> setVolume(
    lk.RemoteParticipant participant,
    double volume,
  ) async {
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    final identity = participant.identity.isNotEmpty
        ? participant.identity
        : participant.sid.toString();
    _volumes[identity] = clamped;
    await _apply(participant, clamped);
  }

  /// Reapplies the stored volume (if any) to all of [participant]'s audio
  /// tracks. Useful after subscription changes — e.g. a track is added later
  /// than the slider was first moved.
  Future<void> reapply(lk.RemoteParticipant participant) async {
    final identity = participant.identity.isNotEmpty
        ? participant.identity
        : participant.sid.toString();
    final stored = _volumes[identity];
    if (stored == null) return;
    await _apply(participant, stored);
  }

  Future<void> _apply(lk.RemoteParticipant participant, double volume) async {
    for (final pub in participant.audioTrackPublications) {
      final track = pub.track;
      if (track == null) continue;
      try {
        await rtc.Helper.setVolume(volume, track.mediaStreamTrack);
      } catch (_) {
        // Volume control is non-critical — swallow per-track failures so a
        // single bad track doesn't break the slider for the others.
      }
    }
  }
}
