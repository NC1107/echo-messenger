/// Shared screen-share start/stop flow used by both the sidebar voice
/// dock and the floating dock inside the voice lounge. Keeps the two
/// entry points behavior-identical (#911).
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import 'echo_screen_select_dialog.dart';

bool _useLiveKitPicker() {
  // Desktop uses EchoScreenSelectDialog (DesktopCapturer); Linux xdg-portal handshake is flaky (#12).
  if (kIsWeb) return false;
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return true;
  return false;
}

/// In-flight guard for [toggleScreenShare]. The iOS broadcast picker
/// is asynchronous: the user taps Share, the picker appears, they tap
/// "Start Broadcast", and only then does ReplayKit fire
/// `broadcastStarted`. If the user (or a jittery tap) fires a second
/// toggle while the first is mid-flight, ReplayKit reports
/// "Recording interrupted by another application" and the user has
/// to tap 2-3 times before a share actually sticks (#mobile-voice).
///
/// Library-level so the guard is shared across both entry points
/// (sidebar voice dock + lounge floating dock).
bool _toggleInFlight = false;

/// Settle delay between stopping a share and accepting the next
/// toggle. On iOS, ReplayKit needs a moment for `broadcastFinished`
/// to fully tear down the extension before a new
/// `RPSystemBroadcastPickerView` press won't collide with the
/// previous session.
const Duration _iosBroadcastSettle = Duration(milliseconds: 600);

/// Unpublish, stop, and dispose every screen-share publication on [local].
///
/// Used both when stopping an active share (#936) and as a defensive sweep
/// before starting a new one on platforms that may have stale publications.
Future<void> _cleanupScreenSharePubs(lk.LocalParticipant local) async {
  final pubs = local.videoTrackPublications
      .where((pub) => pub.source == lk.TrackSource.screenShareVideo)
      .toList();
  for (final pub in pubs) {
    final track = pub.track;
    try {
      await local.removePublishedTrack(pub.sid);
    } catch (e) {
      debugPrint('[ScreenShare] removePublishedTrack failed: $e');
    }
    if (track is lk.LocalVideoTrack) {
      try {
        await track.stop();
      } catch (e) {
        debugPrint('[ScreenShare] track.stop failed: $e');
      }
      try {
        await track.dispose();
      } catch (e) {
        debugPrint('[ScreenShare] track.dispose failed: $e');
      }
    }
  }
}

/// Stop an active screen share and flip provider state to inactive.
Future<void> _stopScreenShare(
  LiveKitVoiceNotifier lkNotifier,
  ScreenShare ssNotifier,
) async {
  // #936: Full unpublish/stop/dispose so the next start gets a fresh portal source, not white frames.
  final local = lkNotifier.room?.localParticipant;
  if (local != null) {
    await _cleanupScreenSharePubs(local);
  }
  // Still call the LiveKit notifier so its internal flag flips false and
  // any SDK-side bookkeeping (audio capture, signaling) settles cleanly.
  await lkNotifier.setScreenShareEnabled(false);
  ssNotifier.setLiveKitScreenShareActive(false);
}

/// Start screen share via the custom Echo source-picker dialog (macOS/Windows).
Future<void> _startScreenShareWithPicker(
  BuildContext context,
  LiveKitVoiceNotifier lkNotifier,
  ScreenShare ssNotifier,
) async {
  try {
    // lk.ScreenSelectDialog has two bugs (no errorBuilder, setState-after-dispose); use our picker.
    final source = await showEchoScreenSelectDialog(context);
    if (source == null || !context.mounted) return;
    final track = await lk.LocalVideoTrack.createScreenShareTrack(
      lk.ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
    );
    final room = lkNotifier.room;
    if (room != null) {
      // #910: single-layer VP8 — camera-shaped simulcast default gets dropped by SFU on macOS/Windows.
      await room.localParticipant?.publishVideoTrack(
        track,
        publishOptions: const lk.VideoPublishOptions(
          simulcast: false,
          videoCodec: 'vp8',
        ),
      );
      ssNotifier.setLiveKitScreenShareActive(true);
    }
  } catch (e) {
    debugPrint('[ScreenShare] Desktop screen share failed: $e');
  }
}

/// Start screen share via the platform's native picker (mobile/web).
Future<void> _startScreenShareNative(
  LiveKitVoiceNotifier lkNotifier,
  ScreenShare ssNotifier,
) async {
  // #936: sweep leftover pubs first — stale-track unmute publishes white frames if state drifts.
  final local = lkNotifier.room?.localParticipant;
  if (local != null) {
    await _cleanupScreenSharePubs(local);
  }
  final ok = await lkNotifier.setScreenShareEnabled(true);
  if (ok) {
    ssNotifier.setLiveKitScreenShareActive(true);
  } else {
    // Defensive: if the SDK reports failure (broadcast picker dismissed,
    // permission denied, ReplayKit interrupted), make sure provider state
    // doesn't drift to "sharing" — otherwise the next tap would hit the
    // stop path instead of the start path and the user would have to
    // tap a third time to recover. (#mobile-voice)
    ssNotifier.setLiveKitScreenShareActive(false);
  }
}

/// Toggle screen share for the current LiveKit room.
///
/// On desktop (macOS, Windows, Linux), opens [EchoScreenSelectDialog] so the
/// user can pick a specific window or screen, creates a [LocalVideoTrack] from
/// the selected source, and publishes it to the room with a single-layer VP8
/// publish (no simulcast). On mobile / web the LiveKit notifier handles source
/// selection internally via the platform's native picker.
///
/// Guarded against rapid re-entry: if a previous toggle is still in flight
/// the second call is ignored. This is what fixed the "3-taps-to-share"
/// behaviour on iOS — every tap before ReplayKit settled was issuing a
/// fresh `setScreenShareEnabled` that ReplayKit then treated as an
/// "interrupting application" (#mobile-voice).
///
/// No-op when not in a voice channel (no room available).
Future<void> toggleScreenShare(BuildContext context, WidgetRef ref) async {
  if (_toggleInFlight) {
    debugPrint('[ScreenShare] toggle ignored: previous toggle still in flight');
    return;
  }
  _toggleInFlight = true;
  try {
    final screenShare = ref.read(screenShareProvider);
    final lkNotifier = ref.read(livekitVoiceProvider.notifier);
    final ssNotifier = ref.read(screenShareProvider.notifier);

    if (screenShare.isScreenSharing) {
      await _stopScreenShare(lkNotifier, ssNotifier);
      // On iOS, give ReplayKit a moment to fully tear the broadcast
      // extension down before this method returns. Without the settle,
      // a "start" tap immediately after a "stop" tap collides with the
      // outgoing extension and surfaces as "Recording interrupted by
      // another application".
      if (!kIsWeb && Platform.isIOS) {
        await Future<void>.delayed(_iosBroadcastSettle);
      }
      return;
    }

    if (_useLiveKitPicker()) {
      await _startScreenShareWithPicker(context, lkNotifier, ssNotifier);
    } else {
      await _startScreenShareNative(lkNotifier, ssNotifier);
    }
  } finally {
    _toggleInFlight = false;
  }
}
