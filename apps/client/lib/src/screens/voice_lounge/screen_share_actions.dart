/// Shared screen-share start/stop flow used by both the sidebar voice
/// dock and the floating dock inside the voice lounge. Keeps the two
/// entry points behavior-identical (#911).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import 'echo_screen_select_dialog.dart';

bool _useLiveKitPicker() {
  // macOS, Windows, and Linux: use EchoScreenSelectDialog which enumerates
  // sources via flutter_webrtc's DesktopCapturer (no portal dependency).
  //
  // Linux previously deferred to flutter_webrtc's setScreenShareEnabled which
  // was supposed to route through xdg-desktop-portal. In practice the portal
  // handshake is unreliable — it returns "source not found" when the portal
  // daemon isn't running or dismisses the picker before flutter_webrtc reads
  // the result (#12). Using the same custom picker path as macOS/Windows
  // bypasses the portal entirely and gives consistent source enumeration.
  if (kIsWeb) return false;
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return true;
  return false;
}

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
  // #936: Explicitly unpublish + stop + dispose the screen-share publication
  // so the next start request acquires a brand-new portal source instead of
  // reusing a stale reference that would publish white frames.
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
    // Use our custom picker instead of lk.ScreenSelectDialog, which has two
    // bugs: Image.memory without errorBuilder (crashes on non-decodable
    // thumbnail bytes) and a setState-after-dispose race on dismiss.
    final source = await showEchoScreenSelectDialog(context);
    if (source == null || !context.mounted) return;
    final track = await lk.LocalVideoTrack.createScreenShareTrack(
      lk.ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
    );
    final room = lkNotifier.room;
    if (room != null) {
      // #910: explicit single-layer VP8 publish for screen-share. Without
      // this, the SDK falls back to `roomOptions.defaultVideoPublishOptions`
      // which is tuned for camera (simulcast=true + a camera-shaped
      // VideoEncoding). On macOS/Windows that combination negotiates a
      // simulcast layout that the SFU silently drops for remote viewers —
      // the sharer keeps their local preview (no SFU round-trip) but
      // remotes see no track. A single-layer VP8 publish matches what
      // LiveKit's own meet sample uses for screen-share and is decodable
      // everywhere flutter_webrtc runs.
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
  // #936: defensively sweep any leftover screen-share publication before
  // asking LiveKit to enable one. If the toggle state in
  // [screenShareProvider] ever drifts out of sync with LiveKit's internal
  // `getTrackPublicationBySource`, the SDK would take the
  // `unmute(stale-track)` branch and publish white frames instead of
  // creating a fresh track from the portal source the user just picked.
  // Cheap no-op when there's nothing stale to clear.
  final local = lkNotifier.room?.localParticipant;
  if (local != null) {
    await _cleanupScreenSharePubs(local);
  }
  final ok = await lkNotifier.setScreenShareEnabled(true);
  if (ok) {
    ssNotifier.setLiveKitScreenShareActive(true);
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
/// No-op when not in a voice channel (no room available).
Future<void> toggleScreenShare(BuildContext context, WidgetRef ref) async {
  final screenShare = ref.read(screenShareProvider);
  final lkNotifier = ref.read(livekitVoiceProvider.notifier);
  final ssNotifier = ref.read(screenShareProvider.notifier);

  if (screenShare.isScreenSharing) {
    await _stopScreenShare(lkNotifier, ssNotifier);
    return;
  }

  if (_useLiveKitPicker()) {
    await _startScreenShareWithPicker(context, lkNotifier, ssNotifier);
  } else {
    await _startScreenShareNative(lkNotifier, ssNotifier);
  }
}
