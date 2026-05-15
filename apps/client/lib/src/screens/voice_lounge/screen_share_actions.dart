/// Shared screen-share start/stop flow used by both the sidebar voice
/// dock and the floating dock inside the voice lounge. Keeps the two
/// entry points behavior-identical (#911).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';

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
    await lkNotifier.setScreenShareEnabled(false);
    ssNotifier.setLiveKitScreenShareActive(false);
    return;
  }

  if (_useLiveKitPicker()) {
    try {
      final source = await showDialog<DesktopCapturerSource>(
        context: context,
        builder: (_) => lk.ScreenSelectDialog(),
      );
      if (source == null || !context.mounted) return;
      final track = await lk.LocalVideoTrack.createScreenShareTrack(
        lk.ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
      );
      final room = lkNotifier.room;
      if (room != null) {
        await room.localParticipant?.publishVideoTrack(track);
        ssNotifier.setLiveKitScreenShareActive(true);
      }
    } catch (e) {
      debugPrint('[ScreenShare] Desktop screen share failed: $e');
    }
  } else {
    // Mobile / Web / Linux: let LiveKit route through the platform's
    // native picker (xdg-desktop-portal on Linux Wayland, system sheet
    // on iOS / Android, the browser's getDisplayMedia chooser on web).
    final ok = await lkNotifier.setScreenShareEnabled(true);
    if (ok) {
      ssNotifier.setLiveKitScreenShareActive(true);
    }
  }
}
