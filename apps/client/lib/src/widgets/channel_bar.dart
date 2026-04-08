import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/channel.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

class ChannelBar extends ConsumerStatefulWidget {
  final String conversationId;
  final String? selectedTextChannelId;
  final String? activeVoiceChannelId;
  final bool hideVoiceDock;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String?> onVoiceChannelChanged;

  const ChannelBar({
    super.key,
    required this.conversationId,
    this.selectedTextChannelId,
    this.activeVoiceChannelId,
    this.hideVoiceDock = false,
    required this.onTextChannelChanged,
    required this.onVoiceChannelChanged,
  });

  @override
  ConsumerState<ChannelBar> createState() => _ChannelBarState();
}

class _ChannelBarState extends ConsumerState<ChannelBar> {
  String? _lastAutoSelectedConversationId;
  bool _voiceCleanupInFlight = false;
  late final LiveKitVoiceNotifier _voiceRtcNotifier;

  @override
  void initState() {
    super.initState();
    _voiceRtcNotifier = ref.read(livekitVoiceProvider.notifier);
  }

  void _syncDerivedState(ChannelsState channelsState, String myUserId) {
    final channels = channelsState.channelsFor(widget.conversationId);
    final textChannels = channels.where((c) => c.isText).toList();

    if (widget.selectedTextChannelId == null &&
        textChannels.isNotEmpty &&
        _lastAutoSelectedConversationId != widget.conversationId) {
      _lastAutoSelectedConversationId = widget.conversationId;
      widget.onTextChannelChanged(textChannels.first.id);
    }

    final activeVoice = widget.activeVoiceChannelId;
    if (activeVoice == null || _voiceCleanupInFlight) return;

    final iAmInChannel = channelsState
        .voiceSessionsFor(activeVoice)
        .any((p) => p.userId == myUserId);
    if (iAmInChannel) return;

    _voiceCleanupInFlight = true;
    _voiceRtcNotifier.leaveChannel().whenComplete(() {
      _voiceCleanupInFlight = false;
      if (!mounted) return;
      widget.onVoiceChannelChanged(null);
    });
  }

  @override
  void didUpdateWidget(covariant ChannelBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversationId != oldWidget.conversationId) {
      // Voice state persists globally across conversation navigation.
      // The user explicitly leaves via the hangup button.
      _lastAutoSelectedConversationId = null;
    }
  }

  @override
  void dispose() {
    // Voice state persists globally -- the user disconnects via the hangup
    // button, not by navigating away from a channel bar.
    super.dispose();
  }

  Future<void> _syncVoiceState() async {
    final channelId = widget.activeVoiceChannelId;
    if (channelId == null) return;
    final voiceSettings = ref.read(voiceSettingsProvider);
    await ref
        .read(channelsProvider.notifier)
        .updateVoiceState(
          conversationId: widget.conversationId,
          channelId: channelId,
          isMuted: voiceSettings.selfMuted,
          isDeafened: voiceSettings.selfDeafened,
          pushToTalk: voiceSettings.pushToTalkEnabled,
        );
  }

  Future<bool> _confirmVoiceJoin(String channelName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Join Voice Channel?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Join $channelName now? Your microphone will be enabled based on your voice settings.',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  Future<void> _leaveVoiceChannel(String channelId) async {
    final channelsNotifier = ref.read(channelsProvider.notifier);
    final rtcNotifier = ref.read(livekitVoiceProvider.notifier);

    // Leave: always clean up local state, even if server returns 400.
    await channelsNotifier.leaveVoiceChannel(widget.conversationId, channelId);
    await rtcNotifier.leaveChannel();

    if (!mounted) return;
    widget.onVoiceChannelChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final channelsState = ref.watch(channelsProvider);
    final voiceRtc = ref.watch(livekitVoiceProvider);
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final authState = ref.watch(authProvider);
    final screenShare = ref.watch(screenShareProvider);
    final myUserId = authState.userId ?? '';

    ref.listen<ChannelsState>(channelsProvider, (previous, next) {
      _syncDerivedState(next, myUserId);
    });

    final channels = channelsState.channelsFor(widget.conversationId);
    final textChannels = channels.where((c) => c.isText).toList();
    final voiceChannels = channels.where((c) => c.isVoice).toList();
    final activeVoice = widget.activeVoiceChannelId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildInlineGroupChannels(
          channels,
          textChannels,
          voiceChannels,
          channelsState,
          voiceSettings,
          activeVoice,
        ),
        if (screenShare.isScreenSharing) _buildScreenSharePreview(),
        if (activeVoice != null && voiceRtc.isActive) _buildVideoGrid(voiceRtc),
        if (activeVoice != null && !widget.hideVoiceDock)
          _buildVoiceControlDock(
            channels,
            channelsState,
            voiceSettings,
            myUserId,
            voiceRtc,
            activeVoice,
          ),
      ],
    );
  }

  String _channelStatusLabel(ChannelsState channelsState) {
    if (channelsState.isLoadingConversation(widget.conversationId)) {
      return 'Loading channels...';
    }
    return 'No channels yet';
  }

  Widget _buildTextChannelChip(GroupChannel channel) {
    final isSelected = widget.selectedTextChannelId == channel.id;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => widget.onTextChannelChanged(channel.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? context.accent.withValues(alpha: 0.15)
                : context.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? context.accent.withValues(alpha: 0.4)
                  : context.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tag,
                size: 14,
                color: isSelected ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                channel.name,
                style: TextStyle(
                  color: isSelected ? context.accent : context.textPrimary,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceChannelChip(
    GroupChannel channel,
    int participantCount,
    VoiceSettingsState voiceSettings,
    String? activeVoiceChannelId,
  ) {
    final isActive = activeVoiceChannelId == channel.id;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final channelsNotifier = ref.read(channelsProvider.notifier);
          final rtcNotifier = ref.read(livekitVoiceProvider.notifier);
          if (isActive) {
            await _leaveVoiceChannel(channel.id);
          } else {
            final shouldJoin = await _confirmVoiceJoin(channel.name);
            if (!shouldJoin) return;
            final success = await channelsNotifier.joinVoiceChannel(
              widget.conversationId,
              channel.id,
            );
            if (success && mounted) {
              await rtcNotifier.joinChannel(
                conversationId: widget.conversationId,
                channelId: channel.id,
                startMuted:
                    voiceSettings.selfMuted || voiceSettings.selfDeafened,
              );
              if (mounted) widget.onVoiceChannelChanged(channel.id);
            }
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isActive
                ? context.accent.withValues(alpha: 0.15)
                : context.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isActive
                  ? context.accent.withValues(alpha: 0.4)
                  : context.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.headset_mic_outlined,
                size: 14,
                color: isActive ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                channel.name,
                style: TextStyle(
                  color: isActive ? context.accent : context.textPrimary,
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (participantCount > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '($participantCount)',
                  style: TextStyle(color: context.textMuted, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineGroupChannels(
    List<GroupChannel> channels,
    List<GroupChannel> textChannels,
    List<GroupChannel> voiceChannels,
    ChannelsState channelsState,
    VoiceSettingsState voiceSettings,
    String? activeVoiceChannelId,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: channels.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, bottom: 4),
              child: Text(
                _channelStatusLabel(channelsState),
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final channel in textChannels) ...[
                    _buildTextChannelChip(channel),
                    const SizedBox(width: 6),
                  ],
                  for (final channel in voiceChannels) ...[
                    _buildVoiceChannelChip(
                      channel,
                      channelsState.voiceSessionsFor(channel.id).length,
                      voiceSettings,
                      activeVoiceChannelId,
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Screen share preview
  // ---------------------------------------------------------------------------

  Widget _buildScreenSharePreview() {
    final renderer = ref.read(screenShareProvider.notifier).screenRenderer;
    if (renderer == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          ),
          Positioned(
            top: 6,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: EchoTheme.danger.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.screen_share, size: 12, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    'Screen sharing',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.95),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 6,
            child: IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.white),
              tooltip: 'Stop sharing',
              onPressed: () async {
                await ref.read(screenShareProvider.notifier).stopScreenShare();
              },
              style: IconButton.styleFrom(
                backgroundColor: EchoTheme.danger.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(24, 24),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Voice control dock helpers
  // ---------------------------------------------------------------------------

  Future<void> _toggleMute(VoiceSettingsState voiceSettings) async {
    final notifier = ref.read(voiceSettingsProvider.notifier);
    final nextMuted = !voiceSettings.selfMuted;
    await notifier.setSelfMuted(nextMuted);
    ref
        .read(livekitVoiceProvider.notifier)
        .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
    await _syncVoiceState();
  }

  Future<void> _toggleDeafen(VoiceSettingsState voiceSettings) async {
    final notifier = ref.read(voiceSettingsProvider.notifier);
    final nextDeafened = !voiceSettings.selfDeafened;
    await notifier.setSelfDeafened(nextDeafened);
    final lkNotifier = ref.read(livekitVoiceProvider.notifier);
    // Let setDeafened handle mic state internally -- calling
    // setCaptureEnabled before setDeafened corrupts _wasMutedBeforeDeafen.
    await lkNotifier.setDeafened(nextDeafened);
    await _syncVoiceState();
  }

  Future<void> _togglePushToTalk(VoiceSettingsState voiceSettings) async {
    final notifier = ref.read(voiceSettingsProvider.notifier);
    final next = !voiceSettings.pushToTalkEnabled;
    await notifier.setPushToTalkEnabled(next);
    ref
        .read(livekitVoiceProvider.notifier)
        .setCaptureEnabled(
          !next && !voiceSettings.selfMuted && !voiceSettings.selfDeafened,
        );
    await _syncVoiceState();
  }

  Widget _buildMuteButton(VoiceSettingsState voiceSettings) {
    final micOff = voiceSettings.selfMuted || voiceSettings.selfDeafened;
    return IconButton(
      icon: Icon(micOff ? Icons.mic_off : Icons.mic, size: 18),
      color: voiceSettings.selfMuted
          ? EchoTheme.danger
          : voiceSettings.selfDeafened
          ? context.textMuted
          : context.textSecondary,
      tooltip: voiceSettings.selfDeafened
          ? 'Muted by deafen'
          : voiceSettings.selfMuted
          ? 'Unmute'
          : 'Mute',
      onPressed: () => _toggleMute(voiceSettings),
    );
  }

  Widget _buildDeafenButton(VoiceSettingsState voiceSettings) {
    return IconButton(
      icon: Icon(
        voiceSettings.selfDeafened ? Icons.headset_off : Icons.headset,
        size: 18,
      ),
      color: voiceSettings.selfDeafened
          ? EchoTheme.danger
          : context.textSecondary,
      tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
      onPressed: () => _toggleDeafen(voiceSettings),
    );
  }

  Widget _buildPttButton(VoiceSettingsState voiceSettings) {
    return TextButton(
      onPressed: () => _togglePushToTalk(voiceSettings),
      child: Text(
        voiceSettings.pushToTalkEnabled
            ? 'PTT ${voiceSettings.pushToTalkKeyLabel}'
            : 'PTT Off',
      ),
    );
  }

  Widget _buildJoiningIndicator() {
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(strokeWidth: 2, color: context.accent),
    );
  }

  Widget _buildConnectedIndicator() {
    return const Icon(
      Icons.fiber_manual_record,
      size: 10,
      color: EchoTheme.online,
    );
  }

  Widget _buildVideoButton(LiveKitVoiceState voiceRtc) {
    return IconButton(
      icon: Icon(
        voiceRtc.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
        size: 18,
      ),
      color: voiceRtc.isVideoEnabled ? context.accent : context.textSecondary,
      tooltip: voiceRtc.isVideoEnabled ? 'Turn off camera' : 'Turn on camera',
      onPressed: () => ref.read(livekitVoiceProvider.notifier).toggleVideo(),
    );
  }

  /// Build a grid of video tiles for participants with active video.
  Widget _buildVideoGrid(LiveKitVoiceState voiceRtc) {
    final room = ref.read(livekitVoiceProvider.notifier).room;
    if (room == null) return const SizedBox.shrink();

    // Collect video tracks: local camera + remote video tracks.
    final tiles = <Widget>[];

    // Local video tile.
    final localVideo = room.localParticipant?.videoTrackPublications
        .where(
          (pub) => pub.track != null && pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;
    if (localVideo != null && localVideo.track is lk.VideoTrack) {
      tiles.add(
        _LiveKitVideoTile(
          key: const ValueKey('local-video'),
          track: localVideo.track! as lk.VideoTrack,
          label: 'You',
          mirror: true,
        ),
      );
    }

    // Remote video tiles.
    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null && pub.track is lk.VideoTrack) {
          final identity = participant.identity.isNotEmpty
              ? participant.identity
              : participant.sid.toString();
          tiles.add(
            _LiveKitVideoTile(
              key: ValueKey('remote-video-${participant.sid}'),
              track: pub.track! as lk.VideoTrack,
              label: identity.length >= 8 ? identity.substring(0, 8) : identity,
              mirror: false,
            ),
          );
        }
      }
    }

    if (tiles.isEmpty) return const SizedBox.shrink();

    final crossAxisCount = tiles.length <= 1
        ? 1
        : tiles.length <= 4
        ? 2
        : 3;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: GridView.count(
        crossAxisCount: crossAxisCount,
        shrinkWrap: true,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 4 / 3,
        children: tiles,
      ),
    );
  }

  /// Format peer latency as a compact string, e.g. "42ms".
  String _formatLatency(LiveKitVoiceState voiceRtc) {
    final latencies = voiceRtc.peerLatencies;
    if (latencies.isEmpty) return '';
    // Show average RTT across all peers.
    final avgMs =
        (latencies.values.reduce((a, b) => a + b) / latencies.length * 1000)
            .round();
    return '${avgMs}ms';
  }

  Widget _buildCompactVoiceDock({
    required GroupChannel activeVoiceChannel,
    required LiveKitVoiceState voiceRtc,
    required VoiceSettingsState voiceSettings,
    required bool iAmConnected,
  }) {
    final latencyLabel = _formatLatency(voiceRtc);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, size: 16, color: context.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Connected to ${activeVoiceChannel.name} '
                '${voiceRtc.peerConnectionStates.length} peer(s)'
                '${latencyLabel.isNotEmpty ? ' \u00b7 $latencyLabel' : ''}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (iAmConnected) _buildConnectedIndicator(),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _buildVideoButton(voiceRtc),
            _buildMuteButton(voiceSettings),
            _buildDeafenButton(voiceSettings),
            _buildPttButton(voiceSettings),
            TextButton.icon(
              onPressed: () => _leaveVoiceChannel(activeVoiceChannel.id),
              icon: const Icon(Icons.call_end, size: 16),
              label: const Text('Leave'),
              style: TextButton.styleFrom(foregroundColor: EchoTheme.danger),
            ),
            if (voiceRtc.isJoining) _buildJoiningIndicator(),
          ],
        ),
      ],
    );
  }

  Widget _buildWideVoiceDock({
    required GroupChannel activeVoiceChannel,
    required LiveKitVoiceState voiceRtc,
    required VoiceSettingsState voiceSettings,
    required bool iAmConnected,
  }) {
    final latencyLabel = _formatLatency(voiceRtc);
    return Row(
      children: [
        Icon(Icons.graphic_eq, size: 16, color: context.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Connected to ${activeVoiceChannel.name} '
            '${voiceRtc.peerConnectionStates.length} peer(s)'
            '${latencyLabel.isNotEmpty ? ' \u00b7 $latencyLabel' : ''}',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (voiceRtc.isJoining)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildJoiningIndicator(),
          ),
        _buildVideoButton(voiceRtc),
        _buildMuteButton(voiceSettings),
        _buildDeafenButton(voiceSettings),
        _buildPttButton(voiceSettings),
        IconButton(
          icon: const Icon(Icons.call_end, size: 18),
          color: EchoTheme.danger,
          tooltip: 'Leave',
          onPressed: () => _leaveVoiceChannel(activeVoiceChannel.id),
        ),
        if (iAmConnected) _buildConnectedIndicator(),
      ],
    );
  }

  Widget _buildVoiceControlDock(
    List<GroupChannel> channels,
    ChannelsState channelsState,
    VoiceSettingsState voiceSettings,
    String myUserId,
    LiveKitVoiceState voiceRtc,
    String? activeVoiceChannelId,
  ) {
    final activeVoiceChannel = channels
        .where((c) => c.id == activeVoiceChannelId)
        .firstOrNull;
    if (activeVoiceChannel == null) return const SizedBox.shrink();

    final participants = channelsState.voiceSessionsFor(activeVoiceChannel.id);
    final isCompact = MediaQuery.of(context).size.width < 720;
    final iAmConnected = participants.any((p) => p.userId == myUserId);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: isCompact
          ? _buildCompactVoiceDock(
              activeVoiceChannel: activeVoiceChannel,
              voiceRtc: voiceRtc,
              voiceSettings: voiceSettings,
              iAmConnected: iAmConnected,
            )
          : _buildWideVoiceDock(
              activeVoiceChannel: activeVoiceChannel,
              voiceRtc: voiceRtc,
              voiceSettings: voiceSettings,
              iAmConnected: iAmConnected,
            ),
    );
  }
}

/// A video tile that renders a LiveKit [lk.VideoTrack] using the SDK's
/// built-in [lk.VideoTrackRenderer] widget.
class _LiveKitVideoTile extends StatelessWidget {
  final lk.VideoTrack track;
  final String label;
  final bool mirror;

  const _LiveKitVideoTile({
    super.key,
    required this.track,
    required this.label,
    this.mirror = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        color: Colors.black87,
        child: Stack(
          fit: StackFit.expand,
          children: [
            lk.VideoTrackRenderer(
              track,
              fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              mirrorMode: mirror
                  ? lk.VideoViewMirrorMode.mirror
                  : lk.VideoViewMirrorMode.off,
            ),
            Positioned(
              bottom: 4,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
