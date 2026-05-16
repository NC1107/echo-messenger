part of 'livekit_voice_provider.dart';

/// Microphone, camera, screen-share, and video-quality controls for the
/// LiveKit voice notifier. Pure media-control surface — no room-lifecycle
/// or token-fetch concerns.
///
/// Mixed into [LiveKitVoiceNotifier]. Reaches the shared `_room` /
/// `_disposed` / `_wasMutedBeforeDeafen` fields back through abstract
/// accessors so the field declarations stay in one place on the facade.
mixin LiveKitVoiceAvControlsMixin on Notifier<LiveKitVoiceState> {
  /// Active LiveKit room (null when not joined). Provided by the facade.
  Room? get _room;

  /// True after [LiveKitVoiceNotifier.dispose]; gates async callbacks
  /// that would otherwise race the disposed state. Provided by the facade.
  bool get _disposed;

  /// Tracks whether mic was muted before deafening so un-deafen restores
  /// the previous mute state instead of always enabling the mic.
  bool get _wasMutedBeforeDeafen;
  set _wasMutedBeforeDeafen(bool value);

  /// Enable or disable the local microphone.
  void setCaptureEnabled(bool enabled) {
    DebugLogService.instance.log(
      LogLevel.info,
      'LiveKitVoice',
      'setCaptureEnabled($enabled)',
    );
    // Wrap the setMicrophoneEnabled call so a native audio-session error
    // (e.g. AVAudioSession activation race on iOS) doesn't surface as an
    // unhandled exception into the Riverpod error boundary.  State is still
    // updated optimistically so the UI reflects the intended mute state;
    // if the underlying track fails, LiveKit will emit a disconnect or
    // error event through the room listener.
    final future = _room?.localParticipant?.setMicrophoneEnabled(enabled);
    if (future != null) {
      // ignore: unawaited_futures
      future.then((_) {}).catchError((Object e) {
        DebugLogService.instance.log(
          LogLevel.error,
          'LiveKitVoice',
          'setCaptureEnabled($enabled): setMicrophoneEnabled threw: $e',
        );
      });
    }
    state = state.copyWith(isCaptureEnabled: enabled);
  }

  /// Mute/unmute all incoming audio from remote participants.
  ///
  /// Following Discord convention, deafening also mutes the microphone.
  /// Un-deafening restores mic to whatever state it was before deafening.
  Future<void> setDeafened(bool deafened) async {
    _syncMicStateForDeafen(deafened);
    await _setRemoteAudioEnabled(!deafened);
    state = state.copyWith(isDeafened: deafened);
  }

  /// Save mic state and mute/unmute for deafen toggle.
  void _syncMicStateForDeafen(bool deafened) {
    if (deafened) {
      _wasMutedBeforeDeafen = !state.isCaptureEnabled;
      setCaptureEnabled(false);
    } else if (!_wasMutedBeforeDeafen) {
      setCaptureEnabled(true);
    }
  }

  /// Enable or disable all remote participant audio tracks.
  Future<void> _setRemoteAudioEnabled(bool enabled) async {
    final room = _room;
    if (room == null) return;
    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.audioTrackPublications) {
        final track = pub.track;
        if (track != null) {
          enabled ? await track.enable() : await track.disable();
        }
      }
    }
  }

  /// Toggle the local camera on/off.
  Future<void> toggleVideo() async {
    if (_disposed || !state.isActive) return;
    final room = _room;
    if (room == null) return;

    final enabled = !state.isVideoEnabled;
    DebugLogService.instance.log(
      LogLevel.info,
      'LiveKitVoice',
      'toggleVideo: setCameraEnabled($enabled)',
    );
    try {
      await room.localParticipant?.setCameraEnabled(enabled);
      state = state.copyWith(isVideoEnabled: enabled);
      DebugLogService.instance.log(
        LogLevel.info,
        'LiveKitVoice',
        'toggleVideo: camera enabled=$enabled',
      );
    } catch (e) {
      debugPrint('[LiveKitVoice] toggleVideo failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'toggleVideo failed: $e',
      );
      state = state.copyWith(error: _friendlyMediaError(e, 'camera'));
    }
  }

  /// Switch between front and back camera on mobile devices.
  ///
  /// Enumerates video input devices and switches to the next one.
  /// On mobile this toggles front/back; on desktop it cycles through cameras.
  Future<void> switchCamera() async {
    if (_disposed || !state.isActive || !state.isVideoEnabled) return;
    final room = _room;
    if (room == null) return;

    try {
      final cameraPub = room.localParticipant?.videoTrackPublications
          .where((pub) => pub.source == TrackSource.camera && pub.track != null)
          .firstOrNull;

      if (cameraPub?.track case final LocalVideoTrack videoTrack) {
        // Get all video input devices
        final devices = await Hardware.instance.enumerateDevices(
          type: 'videoinput',
        );
        if (devices.length < 2) return; // Only one camera, nothing to switch

        // Find the current device and pick the next one
        final currentId = Hardware.instance.selectedVideoInput?.deviceId ?? '';
        final currentIndex = devices.indexWhere((d) => d.deviceId == currentId);
        final nextIndex = (currentIndex + 1) % devices.length;
        final nextDevice = devices[nextIndex];

        await videoTrack.switchCamera(nextDevice.deviceId);
        Hardware.instance.selectedVideoInput = nextDevice;
      }
    } catch (e) {
      debugPrint('[LiveKitVoice] switchCamera failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'switchCamera failed: $e',
      );
    }
  }

  /// Enable or disable screen sharing via LiveKit.
  ///
  /// On Linux desktop, enumerates available screen/window sources and passes
  /// the first source's ID to the SDK to avoid PipeWire portal failures.
  /// On other platforms, uses the SDK's built-in capture flow.
  Future<bool> setScreenShareEnabled(bool enabled, {String? sourceId}) async {
    if (_disposed || !state.isActive) return false;
    final room = _room;
    if (room == null) return false;

    DebugLogService.instance.log(
      LogLevel.info,
      'LiveKitVoice',
      'setScreenShareEnabled($enabled) on ${defaultTargetPlatform.name}',
    );
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS requires a ReplayKit Broadcast Upload Extension for screen
        // capture. LiveKit's plugin reads RTCScreenSharingExtension from
        // Info.plist and presents the system broadcast picker automatically.
        await room.localParticipant?.setScreenShareEnabled(
          enabled,
          captureScreenAudio: true,
        );
      } else if (!enabled) {
        // Disable path: SDK handles unpublish + track stop internally.
        await room.localParticipant?.setScreenShareEnabled(false);
      } else {
        // #910: Enable path bypasses `setScreenShareEnabled(true)` so we
        // can pass explicit publish options. The SDK shortcut falls back
        // to `roomOptions.defaultVideoPublishOptions`, which is tuned for
        // camera (simulcast=true + a camera-shaped VideoEncoding). For
        // screen-share that combination negotiates a multi-layer simulcast
        // publish that the SFU silently drops for remote viewers — the
        // sharer keeps their local preview (no SFU round-trip) but
        // remotes see no track. A single-layer VP8 publish matches the
        // LiveKit meet sample and is decodable wherever flutter_webrtc
        // runs (Linux xdg-desktop-portal, web getDisplayMedia, Android).
        final captureOptions =
            room.roomOptions.defaultScreenShareCaptureOptions;
        final track = await LocalVideoTrack.createScreenShareTrack(
          captureOptions,
        );
        await room.localParticipant?.publishVideoTrack(
          track,
          publishOptions: const VideoPublishOptions(
            simulcast: false,
            videoCodec: 'vp8',
          ),
        );
      }
      DebugLogService.instance.log(
        LogLevel.info,
        'LiveKitVoice',
        'setScreenShareEnabled($enabled): screen share toggled successfully',
      );
      return true;
    } catch (e) {
      debugPrint('[LiveKitVoice] setScreenShareEnabled($enabled) failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'setScreenShareEnabled($enabled) failed: $e',
      );
      state = state.copyWith(error: _friendlyMediaError(e, 'screen share'));
      return false;
    }
  }

  /// Change the video bitrate and FPS.
  ///
  /// Updates the encoding parameters on the currently published video track
  /// (if any) and stores the preference in state for future publishes.
  Future<void> setVideoParams({int? bitrate, int? fps}) async {
    state = state.copyWith(
      videoBitrate: bitrate ?? state.videoBitrate,
      videoFps: fps ?? state.videoFps,
    );

    await _applyVideoEncoding();
  }

  /// Toggle auto quality mode.
  ///
  /// When enabled, LiveKit adaptive stream manages quality automatically
  /// and manual bitrate/fps settings are ignored.
  Future<void> setAutoQuality(bool enabled) async {
    state = state.copyWith(autoQuality: enabled);
    // Auto quality is handled by the room's adaptiveStream option;
    // manual encoding is only applied when auto quality is off.
    if (!enabled) {
      await _applyVideoEncoding();
    }
  }

  /// Apply the current videoBitrate / videoFps to the active camera track.
  ///
  /// LiveKit 2.7.x throws TrackPublishException when publishVideoTrack is
  /// called on an already-published track, so we unpublish first and then
  /// republish with the new encoding options via a fresh camera track.
  Future<void> _applyVideoEncoding() async {
    final room = _room;
    if (room == null || !state.isVideoEnabled || state.autoQuality) return;

    final localParticipant = room.localParticipant;
    if (localParticipant == null) return;

    final cameraPub = localParticipant.videoTrackPublications
        .where((pub) => pub.source == TrackSource.camera && pub.track != null)
        .firstOrNull;

    if (cameraPub != null) {
      try {
        // Unpublish the existing track; re-publishing the same track object
        // throws TrackPublishException('track already exists') in SDK 2.7.x.
        await localParticipant.removePublishedTrack(cameraPub.sid);
        final newTrack = await LocalVideoTrack.createCameraTrack(
          room.roomOptions.defaultCameraCaptureOptions,
        );
        await localParticipant.publishVideoTrack(
          newTrack,
          publishOptions: VideoPublishOptions(
            videoEncoding: VideoEncoding(
              maxBitrate: state.videoBitrate,
              maxFramerate: state.videoFps,
            ),
          ),
        );
      } catch (e) {
        debugPrint('[LiveKitVoice] setVideoParams failed: $e');
        DebugLogService.instance.log(
          LogLevel.warning,
          'LiveKitVoice',
          'Video params change failed: $e',
        );
      }
    }
  }

  /// Map media errors to user-readable messages shown in the voice UI.
  static String _friendlyMediaError(Object e, String feature) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('notallowederror') || msg.contains('not allowed')) {
      return '${feature[0].toUpperCase()}${feature.substring(1)} permission denied. '
          'Check your browser or system settings.';
    }
    if (msg.contains('source not found') || msg.contains('notfounderror')) {
      if (feature == 'screen share') {
        return 'No screen source found. On Linux, ensure PipeWire and '
            'xdg-desktop-portal are running.';
      }
      return 'No $feature device found.';
    }
    if (msg.contains('not supported') || msg.contains('notsupportederror')) {
      return '${feature[0].toUpperCase()}${feature.substring(1)} is not supported '
          'on this platform.';
    }
    return 'Failed to enable $feature.';
  }
}
