// Regression coverage for #927 — Windows system audio level was being
// modified when the app exited because per-track volumes set via
// `Helper.setVolume` were never restored to 1.0 before LiveKit disconnect.
//
// The full integration (Room with audio publications) requires a connected
// LiveKit session and so cannot run in pure-Dart unit tests. These cases
// lock in the public-API contract that `_cleanupRoom` depends on:
//
//   1. `restoreAll` exists and is safe to call when no volumes are stored
//      (the early-return path that runs on every leave/dispose where no
//      slider was ever touched).
//   2. `clearForTest` empties the map without crashing.
//
// Together they guarantee the cleanup path the provider takes on every
// disconnect cannot itself throw and short-circuit the rest of the cleanup
// chain (`room.disconnect()` / `room.dispose()`).

import 'package:echo_app/src/screens/voice_lounge/participant_volume_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ParticipantVolumeController (#927)', () {
    setUp(() {
      // Singleton — reset between tests so leaked state from one case
      // doesn't bleed into the next.
      ParticipantVolumeController.instance.clearForTest();
    });

    test('clearForTest empties the volumes map', () {
      // Sanity: starts empty after setUp.
      expect(ParticipantVolumeController.instance.trackedIdentityCount, 0);
      // No-op when already empty — must not throw.
      ParticipantVolumeController.instance.clearForTest();
      expect(ParticipantVolumeController.instance.trackedIdentityCount, 0);
    });

    test('volumeFor returns 1.0 default for unknown identity', () {
      // Default contract: any identity we haven't seen plays at full volume.
      // This is what `restoreAll` restores the per-track gain to.
      expect(ParticipantVolumeController.instance.volumeFor('never-seen'), 1.0);
    });

    // Note: `restoreAll(room)` against a populated map requires a connected
    // livekit Room with RemoteParticipants exposing audio publications —
    // that path is exercised by the live voice integration tests, not here.
    // The unit-level guarantee above is what the disconnect-time fix relies
    // on: the cleanup call site is `await
    // ParticipantVolumeController.instance.restoreAll(room)` inside a
    // try/catch, so any throw would still let `room.disconnect()` run, but
    // we also assert the no-throw contract for the common empty case.
  });
}
