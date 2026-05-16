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

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// Active room subscription, if any. Held so [attachRoom] is idempotent and
  /// the listener is torn down before re-binding to a different room.
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  lk.Room? _attachedRoom;

  /// Returns the stored volume for [identity], or 1.0 if none is set.
  ///
  /// Returns 1.0 immediately for an empty identity — SIDs change on every
  /// join so we never key by SID; an empty identity means no customization.
  double volumeFor(String identity) {
    if (identity.isEmpty) return 1.0;
    return _volumes[identity] ?? 1.0;
  }

  /// Test-only window into the stored entries so regression tests can assert
  /// that map cleanup actually drops keys on disconnect.
  @visibleForTesting
  int get trackedIdentityCount => _volumes.length;

  /// Removes the stored volume for [identity] so a stale entry can't be
  /// reapplied if the same identity rejoins later (e.g. through a recycled
  /// identity in a long-running lounge session).
  void clearForIdentity(String identity) {
    _volumes.remove(identity);
  }

  /// Wires a [ParticipantDisconnectedEvent] listener on [room] that drops the
  /// stored volume for the departing participant. Safe to call repeatedly;
  /// re-attaching to the same room is a no-op, and switching rooms tears the
  /// old listener down first.
  ///
  /// Caller should invoke this once per voice lounge session. The controller
  /// is a process-wide singleton so it deliberately does not auto-detach on
  /// the room itself being disposed — that's the room owner's responsibility
  /// via [detachRoom].
  void attachRoom(lk.Room room) {
    if (identical(_attachedRoom, room)) return;
    _roomListener?.dispose();
    _attachedRoom = room;
    final listener = room.createListener();
    listener.on<lk.ParticipantDisconnectedEvent>((event) {
      final identity = event.participant.identity;
      if (identity.isEmpty) return;
      _volumes.remove(identity);
    });
    _roomListener = listener;
  }

  /// Releases the [attachRoom] subscription. Safe to call when nothing is
  /// attached.
  void detachRoom() {
    _roomListener?.dispose();
    _roomListener = null;
    _attachedRoom = null;
  }

  /// Persists [volume] (clamped to 0..1) for [identity] and applies it to
  /// every currently-subscribed audio track on [participant].
  ///
  /// Safe to call repeatedly while the user drags the slider; the underlying
  /// `Helper.setVolume` call is fire-and-forget per track.
  Future<void> setVolume(
    lk.RemoteParticipant participant,
    double volume,
  ) async {
    // SIDs change on every join so they can't reliably key the map; a
    // participant with no stable identity gets no volume customization.
    if (participant.identity.isEmpty) return;
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    _volumes[participant.identity] = clamped;
    await _apply(participant, clamped);
  }

  /// Reapplies the stored volume (if any) to all of [participant]'s audio
  /// tracks. Useful after subscription changes — e.g. a track is added later
  /// than the slider was first moved.
  Future<void> reapply(lk.RemoteParticipant participant) async {
    // SIDs change on every join so they can't reliably key the map; a
    // participant with no stable identity has no stored customization.
    if (participant.identity.isEmpty) return;
    final stored = _volumes[participant.identity];
    if (stored == null) return;
    await _apply(participant, stored);
  }

  /// Resets every adjusted track in [room] back to full volume (1.0) and
  /// clears the stored map. Must run BEFORE [lk.Room.disconnect] so the
  /// underlying [rtc.MediaStreamTrack] objects are still alive when the
  /// `Helper.setVolume` calls land.
  ///
  /// Motivation (#927): on Windows, `flutter_webrtc`'s `Helper.setVolume`
  /// routes through WASAPI per-track gain. If the user dragged a participant
  /// slider to e.g. 40% and the app then exited without restoring the track
  /// to 1.0, the audio session can be released with the reduced gain still
  /// applied — and Windows persists per-app session volume in the system
  /// mixer across launches, leaving Echo Messenger visibly pinned at the
  /// reduced level until the user manually re-adjusts it. Restoring to 1.0
  /// before disconnect lets the session settle at the natural default.
  ///
  /// Non-Windows platforms are unaffected by the underlying bug, but the
  /// restore is also harmless there — `Helper.setVolume(1.0, ...)` is a
  /// no-op when the track is already at full gain.
  Future<void> restoreAll(lk.Room room) async {
    if (_volumes.isEmpty) return;
    // Snapshot identities and clear up-front so a concurrent setVolume()
    // can't repopulate entries we're walking past.
    final adjusted = Set<String>.from(_volumes.keys);
    _volumes.clear();
    for (final participant in room.remoteParticipants.values) {
      final identity = participant.identity.isNotEmpty
          ? participant.identity
          : participant.sid.toString();
      if (!adjusted.contains(identity)) continue;
      await _apply(participant, 1.0);
    }
  }

  /// Test-only: drop the entire volumes map without touching tracks. Used by
  /// regression tests to reset the singleton between cases.
  @visibleForTesting
  void clearForTest() => _volumes.clear();

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
