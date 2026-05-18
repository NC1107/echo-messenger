import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/channel.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/theme_provider.dart' show UIDensity, uiDensityProvider;
import '../providers/voice_settings_provider.dart';
import '../services/debug_log_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';

class ChannelBar extends ConsumerStatefulWidget {
  final String conversationId;
  final String? selectedTextChannelId;
  final String? activeVoiceChannelId;
  final bool hideVoiceDock;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String?> onVoiceChannelChanged;
  final VoidCallback? onShowLounge;

  const ChannelBar({
    super.key,
    required this.conversationId,
    this.selectedTextChannelId,
    this.activeVoiceChannelId,
    this.hideVoiceDock = false,
    required this.onTextChannelChanged,
    required this.onVoiceChannelChanged,
    this.onShowLounge,
  });

  @override
  ConsumerState<ChannelBar> createState() => _ChannelBarState();
}

class _ChannelBarState extends ConsumerState<ChannelBar> {
  String? _lastAutoSelectedConversationId;
  bool _voiceCleanupInFlight = false;
  late final LiveKitVoiceNotifier _voiceRtcNotifier;

  /// Channel ID currently in the process of being joined (HTTP call +
  /// room.connect + setMicrophoneEnabled). Cleared in a `finally` block so
  /// the chip always reverts to its normal icon on success or failure.
  String? _joiningChannelId;

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
    final myUserId = authState.userId ?? '';
    // Phase 2 follow-up: density drives chip padding / icon / font.
    final density = ref.watch(uiDensityProvider);

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
          density,
        ),
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

  /// Phase 2 follow-up: per-density chip metrics.  Same shape as the
  /// switch tables in conversation_item.dart and message_item.dart.
  ({
    EdgeInsets padding,
    double iconSize,
    double labelSize,
    double radius,
    double gap,
  })
  _chipMetrics(UIDensity density) => switch (density) {
    UIDensity.cozy => (
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      iconSize: 16,
      labelSize: 14,
      radius: 22,
      gap: 8,
    ),
    UIDensity.normal => (
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      iconSize: 14,
      labelSize: 12,
      radius: 20,
      gap: 6,
    ),
    UIDensity.compact => (
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      iconSize: 12,
      labelSize: 11,
      radius: 18,
      gap: 4,
    ),
  };

  Widget _buildTextChannelChip(GroupChannel channel, UIDensity density) {
    final isSelected = widget.selectedTextChannelId == channel.id;
    final m = _chipMetrics(density);
    return Semantics(
      label: 'text channel: ${channel.name}',
      button: true,
      selected: isSelected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(m.radius),
          onTap: () => widget.onTextChannelChanged(channel.id),
          child: Container(
            padding: m.padding,
            decoration: BoxDecoration(
              color: isSelected
                  ? context.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(m.radius),
              border: Border.all(
                color: isSelected
                    ? context.accent.withValues(alpha: 0.4)
                    : context.border.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tag,
                  size: m.iconSize,
                  color: isSelected ? context.accent : context.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  channel.name,
                  style: TextStyle(
                    color: isSelected ? context.accent : context.textSecondary,
                    fontSize: m.labelSize,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether a voice channel is currently active (local state or LiveKit).
  bool _isVoiceChannelActive(String channelId, String? activeVoiceChannelId) {
    final voiceRtc = ref.read(livekitVoiceProvider);
    return activeVoiceChannelId == channelId ||
        (voiceRtc.isActive && voiceRtc.channelId == channelId);
  }

  /// Handle tap on a voice channel chip: leave or join.
  Future<void> _handleVoiceChipTap(
    GroupChannel channel,
    bool isActive,
    VoiceSettingsState voiceSettings,
  ) async {
    if (isActive) {
      widget.onShowLounge?.call();
      return;
    }
    if (voiceSettings.confirmBeforeJoinVoice) {
      final shouldJoin = await _confirmVoiceJoin(channel.name);
      if (!shouldJoin) return;
    }

    // Show the per-chip spinner for the duration of the join sequence.
    if (mounted) setState(() => _joiningChannelId = channel.id);

    try {
      // Breadcrumb: write and force-flush to disk synchronously before the
      // LiveKit join so any iOS SIGKILL inside joinChannel still leaves a clear
      // trail.  The blocking write completes in <5 ms on iOS flash storage
      // (buffer is capped at 5000 NDJSON lines, well under 1 MB).
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceLoungeUI',
        'voice channel selected: ${channel.name} id=${channel.id}',
      );
      DebugLogService.instance.forceFlushSync();

      final success = await ref
          .read(channelsProvider.notifier)
          .joinVoiceChannel(widget.conversationId, channel.id);

      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceLoungeUI',
        'joinVoiceChannel result: $success channelId=${channel.id}',
      );

      if (success && mounted) {
        DebugLogService.instance.log(
          LogLevel.info,
          'VoiceLoungeUI',
          'calling livekitVoiceProvider.joinChannel conversationId=${widget.conversationId} channelId=${channel.id}',
        );
        DebugLogService.instance.forceFlushSync();

        await ref
            .read(livekitVoiceProvider.notifier)
            .joinChannel(
              conversationId: widget.conversationId,
              channelId: channel.id,
              startMuted: voiceSettings.selfMuted || voiceSettings.selfDeafened,
            );
        if (!mounted) return;
        widget.onVoiceChannelChanged(channel.id);
        // The voice dock + auto-show-lounge already give the user clear visual
        // feedback that the join succeeded; the snackbar was redundant noise.
      }
    } finally {
      if (mounted) setState(() => _joiningChannelId = null);
    }
  }

  /// Build a stack of up to 3 mini initials avatars with a "+N" overflow label.
  Widget _buildMiniAvatarStack(List<VoiceSessionMember> participants) {
    const radius = 8.0;
    const overlap = 6.0;
    final visible = participants.take(3).toList();
    final overflow = participants.length - visible.length;
    final avatarCount = visible.length;
    // Total width: first avatar full diameter + (n-1) * (diameter - overlap)
    final stackWidth = avatarCount * radius * 2 - (avatarCount - 1) * overlap;

    Widget avatarStack = SizedBox(
      width: stackWidth,
      height: radius * 2,
      child: Stack(
        children: [
          for (int i = 0; i < visible.length; i++)
            Positioned(
              left: i * (radius * 2 - overlap),
              child: CircleAvatar(
                radius: radius,
                backgroundColor: context.accent.withValues(alpha: 0.7),
                child: Text(
                  visible[i].username.isNotEmpty
                      ? visible[i].username[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: 8,
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (overflow <= 0) return avatarStack;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatarStack,
        const SizedBox(width: 3),
        Text(
          '+$overflow',
          style: TextStyle(color: context.textMuted, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildVoiceChannelChip(
    GroupChannel channel,
    List<VoiceSessionMember> participants,
    VoiceSettingsState voiceSettings,
    String? activeVoiceChannelId,
    UIDensity density,
  ) {
    final isActive = _isVoiceChannelActive(channel.id, activeVoiceChannelId);
    final isJoining = _joiningChannelId == channel.id;
    return _VoicePeekChip(
      key: ValueKey('voice-peek-${channel.id}'),
      channel: channel,
      participants: participants,
      isActive: isActive,
      isJoining: isJoining,
      metrics: _chipMetrics(density),
      onTap: () => _handleVoiceChipTap(channel, isActive, voiceSettings),
      miniAvatarStackBuilder: (ps) => _buildMiniAvatarStack(ps),
    );
  }

  Widget _buildInlineGroupChannels(
    List<GroupChannel> channels,
    List<GroupChannel> textChannels,
    List<GroupChannel> voiceChannels,
    ChannelsState channelsState,
    VoiceSettingsState voiceSettings,
    String? activeVoiceChannelId,
    UIDensity density,
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
                    _buildTextChannelChip(channel, density),
                    SizedBox(width: _chipMetrics(density).gap),
                  ],
                  if (textChannels.isNotEmpty && voiceChannels.isNotEmpty)
                    const SizedBox(
                      height: 24,
                      child: VerticalDivider(width: 16, thickness: 1),
                    ),
                  for (final channel in voiceChannels) ...[
                    _buildVoiceChannelChip(
                      channel,
                      channelsState.voiceSessionsFor(channel.id),
                      voiceSettings,
                      activeVoiceChannelId,
                      density,
                    ),
                    SizedBox(width: _chipMetrics(density).gap),
                  ],
                ],
              ),
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
      color: _muteIconColor(context, voiceSettings),
      tooltip: _muteTooltip(voiceSettings),
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

  Color _muteIconColor(BuildContext context, VoiceSettingsState vs) {
    if (vs.selfMuted) return EchoTheme.danger;
    if (vs.selfDeafened) return context.textMuted;
    return context.textSecondary;
  }

  String _muteTooltip(VoiceSettingsState vs) {
    if (vs.selfDeafened) return 'Muted by deafen';
    if (vs.selfMuted) return 'Unmute';
    return 'Mute';
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

  /// Collect local and remote video tiles from the LiveKit room.
  List<Widget> _collectVideoTiles(lk.Room room) {
    final tiles = <Widget>[];
    _addLocalVideoTile(room, tiles);
    _addRemoteVideoTiles(room, tiles);
    return tiles;
  }

  void _addLocalVideoTile(lk.Room room, List<Widget> tiles) {
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
  }

  void _addRemoteVideoTiles(lk.Room room, List<Widget> tiles) {
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
  }

  /// Build a grid of video tiles for participants with active video.
  Widget _buildVideoGrid(LiveKitVoiceState voiceRtc) {
    final room = ref.read(livekitVoiceProvider.notifier).room;
    if (room == null) return const SizedBox.shrink();

    final tiles = _collectVideoTiles(room);
    if (tiles.isEmpty) return const SizedBox.shrink();

    final int crossAxisCount;
    if (tiles.length <= 1) {
      crossAxisCount = 1;
    } else if (tiles.length <= 4) {
      crossAxisCount = 2;
    } else {
      crossAxisCount = 3;
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.videoOverlayBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: GridView.count(
        crossAxisCount: crossAxisCount,
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
    required List<VoiceSessionMember> participants,
  }) {
    final latencyLabel = _formatLatency(voiceRtc);
    final participantNames = participants.map((p) => p.username).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, size: 16, color: context.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${activeVoiceChannel.name}'
                    '${latencyLabel.isNotEmpty ? ' \u00b7 $latencyLabel' : ''}',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (participantNames.isNotEmpty)
                    Text(
                      participantNames,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
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
    required List<VoiceSessionMember> participants,
  }) {
    final latencyLabel = _formatLatency(voiceRtc);
    final participantNames = participants.map((p) => p.username).join(', ');
    return Row(
      children: [
        Icon(Icons.graphic_eq, size: 16, color: context.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${activeVoiceChannel.name}'
                '${latencyLabel.isNotEmpty ? ' \u00b7 $latencyLabel' : ''}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (participantNames.isNotEmpty)
                Text(
                  participantNames,
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
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
    final isCompact = Responsive.width(context) < 720;
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
              participants: participants,
            )
          : _buildWideVoiceDock(
              activeVoiceChannel: activeVoiceChannel,
              voiceRtc: voiceRtc,
              voiceSettings: voiceSettings,
              iAmConnected: iAmConnected,
              participants: participants,
            ),
    );
  }
}

/// Per-density chip metrics, shared between [_ChannelBarState._chipMetrics]
/// and [_VoicePeekChip].
typedef _ChipMetrics = ({
  EdgeInsets padding,
  double iconSize,
  double labelSize,
  double radius,
  double gap,
});

/// Maximum width of the voice-channel peek popover.
const double _kVoicePeekMaxWidth = 240.0;

/// Horizontal padding kept clear of the viewport edge for the peek popover.
const double _kVoicePeekViewportPadding = 8.0;

/// Grace period before the popover hides after the mouse leaves the trigger,
/// so a user can mouse from the chip into the popover without it dismissing.
const Duration _kVoicePeekHoverGrace = Duration(milliseconds: 120);

/// A voice-channel chip in the sidebar that supports a peek popover (hover
/// on desktop / long-press on touch) listing current participants without
/// having to join the channel (#926).
class _VoicePeekChip extends StatefulWidget {
  final GroupChannel channel;
  final List<VoiceSessionMember> participants;
  final bool isActive;

  /// True while the join sequence (HTTP call + room.connect + mic enable) is
  /// in flight for THIS specific channel. Renders a small spinner in place of
  /// the volume icon so the user knows the tap was registered.
  final bool isJoining;

  final _ChipMetrics metrics;
  final VoidCallback onTap;
  final Widget Function(List<VoiceSessionMember>) miniAvatarStackBuilder;

  const _VoicePeekChip({
    super.key,
    required this.channel,
    required this.participants,
    required this.isActive,
    this.isJoining = false,
    required this.metrics,
    required this.onTap,
    required this.miniAvatarStackBuilder,
  });

  @override
  State<_VoicePeekChip> createState() => _VoicePeekChipState();
}

class _VoicePeekChipState extends State<_VoicePeekChip> {
  final OverlayPortalController _popoverController = OverlayPortalController();
  final GlobalKey _triggerKey = GlobalKey();
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_popoverController.isShowing) {
      _popoverController.hide();
    }
    super.dispose();
  }

  void _showPopover() {
    _hideTimer?.cancel();
    if (!_popoverController.isShowing) {
      _popoverController.show();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_kVoicePeekHoverGrace, () {
      if (mounted && _popoverController.isShowing) {
        _popoverController.hide();
      }
    });
  }

  void _togglePopover() {
    _hideTimer?.cancel();
    if (_popoverController.isShowing) {
      _popoverController.hide();
    } else {
      _popoverController.show();
    }
  }

  String _peekSemanticsLabel() {
    final n = widget.participants.length;
    if (n == 0) {
      return 'voice channel: ${widget.channel.name}, no one in voice';
    }
    if (n == 1) {
      return 'voice channel: ${widget.channel.name}, 1 participant';
    }
    return 'voice channel: ${widget.channel.name}, $n participants';
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final isActive = widget.isActive;
    final isJoining = widget.isJoining;
    final participants = widget.participants;

    final chip = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(m.radius),
        onTap: widget.onTap,
        child: Container(
          key: _triggerKey,
          padding: m.padding,
          decoration: BoxDecoration(
            color: isActive
                ? context.accent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(m.radius),
            border: Border.all(
              color: isActive
                  ? context.accent.withValues(alpha: 0.4)
                  : context.border.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isJoining)
                SizedBox(
                  width: m.iconSize,
                  height: m.iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.accent,
                  ),
                )
              else
                Icon(
                  Icons.volume_up_outlined,
                  size: m.iconSize,
                  color: isActive ? context.accent : context.textMuted,
                ),
              const SizedBox(width: 4),
              Text(
                widget.channel.name,
                style: TextStyle(
                  color: isActive ? context.accent : context.textSecondary,
                  fontSize: m.labelSize,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (participants.isNotEmpty) ...[
                const SizedBox(width: 6),
                widget.miniAvatarStackBuilder(participants),
              ],
            ],
          ),
        ),
      ),
    );

    return OverlayPortal(
      controller: _popoverController,
      overlayChildBuilder: (overlayContext) {
        return _VoicePeekOverlay(
          triggerKey: _triggerKey,
          onMouseEnter: _showPopover,
          onMouseExit: _scheduleHide,
          child: _VoicePeekPopover(
            channelName: widget.channel.name,
            participants: participants,
          ),
        );
      },
      child: Semantics(
        button: true,
        label: _peekSemanticsLabel(),
        child: MouseRegion(
          onEnter: (_) => _showPopover(),
          onExit: (_) => _scheduleHide(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: _togglePopover,
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// Positions the voice-peek popover beneath the chip and clamps to the
/// viewport.  Renders an inner [MouseRegion] so the user can mouse from the
/// chip into the popover without it dismissing.
class _VoicePeekOverlay extends StatelessWidget {
  final GlobalKey triggerKey;
  final VoidCallback onMouseEnter;
  final VoidCallback onMouseExit;
  final Widget child;

  const _VoicePeekOverlay({
    required this.triggerKey,
    required this.onMouseEnter,
    required this.onMouseExit,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final triggerCtx = triggerKey.currentContext;
    if (triggerCtx == null) return const SizedBox.shrink();
    final box = triggerCtx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);

    final preferredLeft = offset.dx;
    final maxLeft =
        screen.width - _kVoicePeekMaxWidth - _kVoicePeekViewportPadding;
    final clampedLeft = preferredLeft.clamp(
      _kVoicePeekViewportPadding,
      maxLeft < _kVoicePeekViewportPadding
          ? _kVoicePeekViewportPadding
          : maxLeft,
    );
    final top = offset.dy + size.height + 6;

    return Positioned(
      left: clampedLeft.toDouble(),
      top: top,
      child: MouseRegion(
        onEnter: (_) => onMouseEnter(),
        onExit: (_) => onMouseExit(),
        child: child,
      ),
    );
  }
}

/// The popover body: channel name header + avatar/name list, or an empty
/// state if no one is in the channel.
class _VoicePeekPopover extends StatelessWidget {
  final String channelName;
  final List<VoiceSessionMember> participants;

  const _VoicePeekPopover({
    required this.channelName,
    required this.participants,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: _kVoicePeekMaxWidth),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.volume_up_outlined,
                  size: 14,
                  color: context.textMuted,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    channelName,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (participants.isEmpty)
              Text(
                'No one in voice yet',
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              ...participants.map((p) => _VoicePeekRow(participant: p)),
          ],
        ),
      ),
    );
  }
}

/// A single avatar + username row inside the peek popover.
class _VoicePeekRow extends StatelessWidget {
  final VoiceSessionMember participant;

  const _VoicePeekRow({required this.participant});

  @override
  Widget build(BuildContext context) {
    final initial = participant.username.isNotEmpty
        ? participant.username[0].toUpperCase()
        : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: context.accent.withValues(alpha: 0.7),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              participant.username,
              style: TextStyle(color: context.textPrimary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (participant.isMuted)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.mic_off, size: 12, color: context.textMuted),
            ),
          if (participant.isDeafened)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.headset_off,
                size: 12,
                color: context.textMuted,
              ),
            ),
        ],
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
        color: context.videoOverlayBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            lk.VideoTrackRenderer(
              track,
              fit: lk.VideoViewFit.contain,
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
                  color: context.overlayScrim,
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
