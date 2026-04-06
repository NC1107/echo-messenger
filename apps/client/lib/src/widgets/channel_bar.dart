import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/channel.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/voice_rtc_provider.dart';
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
  late final VoiceRtcNotifier _voiceRtcNotifier;

  @override
  void initState() {
    super.initState();
    _voiceRtcNotifier = ref.read(voiceRtcProvider.notifier);
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
      if (oldWidget.activeVoiceChannelId != null) {
        _voiceRtcNotifier.leaveChannel();
      }
      _lastAutoSelectedConversationId = null;
    }
  }

  @override
  void dispose() {
    if (widget.activeVoiceChannelId != null) {
      _voiceRtcNotifier.leaveChannel();
    }
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
    final rtcNotifier = ref.read(voiceRtcProvider.notifier);

    // Leave: always clean up local state, even if server returns 400.
    await channelsNotifier.leaveVoiceChannel(widget.conversationId, channelId);
    await rtcNotifier.leaveChannel();

    if (!mounted) return;
    widget.onVoiceChannelChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final channelsState = ref.watch(channelsProvider);
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final authState = ref.watch(authProvider);
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

  Widget _buildTextChannelChip(GroupChannel channel) {
    final isSelected = widget.selectedTextChannelId == channel.id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          widget.onTextChannelChanged(channel.id);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected
                  ? context.accent.withValues(alpha: 0.18)
                  : context.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isSelected
                    ? context.accent.withValues(alpha: 0.6)
                    : context.border,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tag, size: 13, color: context.textSecondary),
                const SizedBox(width: 5),
                Text(
                  channel.name,
                  style: TextStyle(
                    color: isSelected ? context.accent : context.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
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
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final channelsNotifier = ref.read(channelsProvider.notifier);
          final rtcNotifier = ref.read(voiceRtcProvider.notifier);
          if (isActive) {
            await _leaveVoiceChannel(channel.id);
          } else {
            // Join
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
              widget.onVoiceChannelChanged(channel.id);
            }
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? context.accent.withValues(alpha: 0.18)
                  : context.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isActive
                    ? context.accent.withValues(alpha: 0.6)
                    : context.border,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.headset_mic_outlined,
                  size: 13,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  channel.name,
                  style: TextStyle(
                    color: isActive ? context.accent : context.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (participantCount > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    '($participantCount)',
                    style: TextStyle(color: context.textMuted, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _channelStatusLabel(ChannelsState channelsState) {
    if (channelsState.isLoadingConversation(widget.conversationId)) {
      return 'Loading channels...';
    }
    return 'No channels yet';
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
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: channels.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _channelStatusLabel(channelsState),
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...textChannels.map(
                    (channel) => _buildTextChannelChip(channel),
                  ),
                  ...voiceChannels.map(
                    (channel) => _buildVoiceChannelChip(
                      channel,
                      channelsState.voiceSessionsFor(channel.id).length,
                      voiceSettings,
                      activeVoiceChannelId,
                    ),
                  ),
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
        .read(voiceRtcProvider.notifier)
        .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
    await _syncVoiceState();
  }

  Future<void> _toggleDeafen(VoiceSettingsState voiceSettings) async {
    final notifier = ref.read(voiceSettingsProvider.notifier);
    final nextDeafened = !voiceSettings.selfDeafened;
    await notifier.setSelfDeafened(nextDeafened);
    final lk = ref.read(voiceRtcProvider.notifier);
    lk.setCaptureEnabled(!voiceSettings.selfMuted && !nextDeafened);
    await lk.setDeafened(nextDeafened);
    await _syncVoiceState();
  }

  Future<void> _togglePushToTalk(VoiceSettingsState voiceSettings) async {
    final notifier = ref.read(voiceSettingsProvider.notifier);
    final next = !voiceSettings.pushToTalkEnabled;
    await notifier.setPushToTalkEnabled(next);
    ref
        .read(voiceRtcProvider.notifier)
        .setCaptureEnabled(
          !next && !voiceSettings.selfMuted && !voiceSettings.selfDeafened,
        );
    await _syncVoiceState();
  }

  Widget _buildMuteButton(VoiceSettingsState voiceSettings) {
    return IconButton(
      icon: Icon(voiceSettings.selfMuted ? Icons.mic_off : Icons.mic, size: 18),
      color: voiceSettings.selfMuted ? EchoTheme.danger : context.textSecondary,
      tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
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

  Widget _buildCompactVoiceDock({
    required GroupChannel activeVoiceChannel,
    required VoiceRtcState voiceRtc,
    required VoiceSettingsState voiceSettings,
    required bool iAmConnected,
  }) {
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
                '${voiceRtc.peerConnectionStates.length} peer(s)',
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
    required VoiceRtcState voiceRtc,
    required VoiceSettingsState voiceSettings,
    required bool iAmConnected,
  }) {
    return Row(
      children: [
        Icon(Icons.graphic_eq, size: 16, color: context.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Connected to ${activeVoiceChannel.name} '
            '${voiceRtc.peerConnectionStates.length} peer(s)',
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
    VoiceRtcState voiceRtc,
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
