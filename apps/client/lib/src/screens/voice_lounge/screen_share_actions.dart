/// Shared screen-share start/stop flow used by both the sidebar voice
/// dock and the floating dock inside the voice lounge. Keeps the two
/// entry points behavior-identical (#911).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import 'echo_screen_select_dialog.dart';

bool _useLiveKitPicker() {
  // macOS and Windows: keep LiveKit's ScreenSelectDialog (no native picker
  // equivalent inside flutter_webrtc on those platforms).
  //
  // Linux: skip the LiveKit dialog. Its Window tab segfaults libwebrtc
  // (#911 follow-up) and the system has xdg-desktop-portal which exposes
  // a much better native picker. Defer to flutter_webrtc's
  // setScreenShareEnabled which routes through the portal.
  if (kIsWeb) return false;
  if (Platform.isMacOS || Platform.isWindows) return true;
  return false;
}

/// Toggle screen share for the current LiveKit room.
///
/// On desktop, opens LiveKit's [ScreenSelectDialog] so the user can pick a
/// specific window or screen, creates a [LocalVideoTrack] from the selected
/// source, and publishes it to the room. On mobile / web the LiveKit
/// notifier handles the source selection internally.
///
/// No-op when not in a voice channel (no room available).
Future<void> toggleScreenShare(BuildContext context, WidgetRef ref) async {
  final screenShare = ref.read(screenShareProvider);
  final lkNotifier = ref.read(livekitVoiceProvider.notifier);
  final ssNotifier = ref.read(screenShareProvider.notifier);

  if (screenShare.isScreenSharing) {
    // #936: On Linux, LiveKit's `setScreenShareEnabled(false)` only mutes /
    // unpublishes the track but can leave the underlying `LocalVideoTrack`
    // (and its now-dead xdg-desktop-portal MediaStream) cached on the
    // participant. A subsequent `setScreenShareEnabled(true)` then reuses
    // that stale reference and the freshly-picked source publishes as a
    // white frame. Explicitly unpublish + stop + dispose the screen-share
    // publication so the next start request is forced to acquire a brand
    // new portal source. Safe on every platform because we walk only the
    // screen-share publication and skip camera tracks.
    final room = lkNotifier.room;
    final local = room?.localParticipant;
    if (local != null) {
      final screenPubs = local.videoTrackPublications
          .where((pub) => pub.source == lk.TrackSource.screenShareVideo)
          .toList();
      for (final pub in screenPubs) {
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
    // Still call the LiveKit notifier so its internal flag flips false and
    // any SDK-side bookkeeping (audio capture, signaling) settles cleanly.
    await lkNotifier.setScreenShareEnabled(false);
    ssNotifier.setLiveKitScreenShareActive(false);
    return;
  }

  if (_useLiveKitPicker()) {
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
  } else {
    // Mobile / Web / Linux: let LiveKit route through the platform's
    // native picker (xdg-desktop-portal on Linux Wayland, system sheet
    // on iOS / Android, the browser's getDisplayMedia chooser on web).
    //
    // #936: defensively sweep any leftover screen-share publication
    // before asking LiveKit to enable one. If the toggle state in
    // [screenShareProvider] ever drifts out of sync with LiveKit's
    // internal `getTrackPublicationBySource`, the SDK would take the
    // `unmute(stale-track)` branch and publish white frames instead of
    // creating a fresh track from the portal source the user just
    // picked. Cheap no-op when there's nothing stale to clear.
    final room = lkNotifier.room;
    final local = room?.localParticipant;
    if (local != null) {
      final stalePubs = local.videoTrackPublications
          .where((pub) => pub.source == lk.TrackSource.screenShareVideo)
          .toList();
      for (final pub in stalePubs) {
        try {
          await local.removePublishedTrack(pub.sid);
        } catch (e) {
          debugPrint('[ScreenShare] stale pub cleanup failed: $e');
        }
      }
    }
    final ok = await lkNotifier.setScreenShareEnabled(true);
    if (ok) {
      ssNotifier.setLiveKitScreenShareActive(true);
    }
  }
}
