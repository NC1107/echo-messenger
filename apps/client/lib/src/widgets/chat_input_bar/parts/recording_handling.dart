// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Voice-record state machine: permission check, recorder.start/stop,
/// amplitude polling for the live waveform, and the post-stop conversion
/// of the captured file into a pending voice attachment.
extension _RecordingHandling on ChatInputBarState {
  Future<void> _syncVoiceState() async {
    final conv = widget.conversation;
    final channelId = widget.effectiveActiveVoiceChannelId;
    if (channelId == null) return;
    final voiceSettings = ref.read(voiceSettingsProvider);
    await ref
        .read(channelsProvider.notifier)
        .updateVoiceState(
          conversationId: conv.id,
          channelId: channelId,
          isMuted: voiceSettings.selfMuted,
          isDeafened: voiceSettings.selfDeafened,
          pushToTalk: voiceSettings.pushToTalkEnabled,
        );
  }

  Future<void> _startRecording() async {
    if (kIsWeb) {
      // Web recording not supported via the record package in this config.
      ToastService.show(
        context,
        'Voice messages are not supported in the browser yet',
        type: ToastType.info,
      );
      return;
    }

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ToastService.show(
          context,
          'Microphone permission is required to send voice messages',
          type: ToastType.error,
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 64000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      // Surface session-init failures (audio busy, codec missing) — previously failed silently (#554).
      debugPrint('[ChatInput] _recorder.start failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Could not start recording: $e',
          type: ToastType.error,
        );
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _recordingDuration = Duration.zero;
      _recordingAmplitudes.clear();
    });

    // Tick every 100ms to update the duration counter and collect amplitudes.
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) async {
      if (!_isRecording || !mounted) return;
      final elapsed = DateTime.now().difference(_recordingStartTime!);
      setState(() => _recordingDuration = elapsed);

      try {
        final amp = await _recorder.getAmplitude();
        // amp.current is in dBFS [-160, 0]. Map to [0, 1].
        final normalised = ((amp.current + 60) / 60).clamp(0.0, 1.0);
        _recordingAmplitudes.add(normalised);
      } catch (_) {
        // Amplitude polling is best-effort.
      }
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    if (!_isRecording) return;

    final path = await _recorder.stop();

    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
    });

    if (cancel || path == null) {
      _recordingAmplitudes.clear();
      return;
    }

    // Read the recorded bytes and attach as a pending voice message.
    try {
      final file = File(path);
      if (!file.existsSync()) {
        if (mounted) {
          ToastService.show(
            context,
            'Recording was lost — no audio file produced',
            type: ToastType.error,
          );
        }
        return;
      }
      final bytes = await file.readAsBytes();
      _recordingAmplitudes.clear();

      // Reject <256B (server rejects 0-byte; 100ms aac is hundreds of bytes) (#554).
      if (bytes.length < 256) {
        if (mounted) {
          ToastService.show(
            context,
            'Recording was too short or silent (${bytes.length}B)',
            type: ToastType.error,
          );
        }
        return;
      }

      _setPendingVoiceAttachment(bytes: bytes);
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Could not read recording: $e',
          type: ToastType.error,
        );
      }
    }
  }

  void _setPendingVoiceAttachment({required Uint8List bytes}) {
    final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _setPendingAttachment(
      bytes: bytes,
      fileName: fileName,
      mimeType: 'audio/mp4',
      ext: 'm4a',
    );
  }
}
