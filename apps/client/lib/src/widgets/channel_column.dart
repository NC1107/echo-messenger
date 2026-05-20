/// Slack/Discord-style vertical channel list.
///
/// An alternative to `channel_bar.dart`'s top-of-chat chip row, selected
/// via the user-facing toggle in [channelLayoutProvider]. Renders the
/// active group's channels grouped by category, with voice channels
/// expanding to show their connected members beneath them. Text channels
/// pick up the same accent-pill selected-state used elsewhere.
///
/// The widget defers to the same providers the bar uses
/// (`channelsProvider` for the channel list, `channelsProvider.notifier`
/// to join voice, `livekitVoiceProvider` for the active voice session),
/// so the two layouts are interchangeable without server work.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/channel.dart';
import '../models/conversation.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor;

class ChannelColumn extends ConsumerWidget {
  final Conversation conversation;
  final String? selectedTextChannelId;
  final ValueChanged<String?> onTextChannelChanged;
  final VoidCallback? onShowLounge;

  /// Fixed column width. 260 matches the Slack/Discord visual baseline
  /// and lets a 1280 desktop window comfortably show
  /// `sidebar + column + chat + members` without crowding.
  static const double width = 260;

  const ChannelColumn({
    super.key,
    required this.conversation,
    required this.selectedTextChannelId,
    required this.onTextChannelChanged,
    this.onShowLounge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsState = ref.watch(channelsProvider);
    final channels = channelsState.channelsFor(conversation.id)
      ..sort((a, b) => a.position.compareTo(b.position));
    final textChannels = channels.where((c) => c.isText).toList();
    final voiceChannels = channels.where((c) => c.isVoice).toList();
    final voiceState = ref.watch(livekitVoiceProvider);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(right: BorderSide(color: context.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ColumnHeader(conversation: conversation),
          Divider(height: 1, color: context.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (textChannels.isNotEmpty) ...[
                  const _CategoryHeader(label: 'Text Channels'),
                  for (final c in textChannels)
                    _TextChannelRow(
                      channel: c,
                      isSelected: c.id == selectedTextChannelId,
                      onTap: () => onTextChannelChanged(c.id),
                    ),
                  const SizedBox(height: 12),
                ],
                if (voiceChannels.isNotEmpty) ...[
                  const _CategoryHeader(label: 'Voice Channels'),
                  for (final c in voiceChannels)
                    _VoiceChannelGroup(
                      channel: c,
                      members: channelsState.voiceSessionsFor(c.id),
                      isActive:
                          voiceState.channelId == c.id &&
                          voiceState.conversationId == conversation.id,
                      onJoin: () => _join(ref, c),
                      onOpenLounge: onShowLounge,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _join(WidgetRef ref, GroupChannel channel) async {
    // Channels notifier owns the HTTP + LiveKit-join handshake; this
    // matches what channel_bar.dart does so behaviour is identical
    // regardless of which layout the user picked.
    await ref
        .read(channelsProvider.notifier)
        .joinVoiceChannel(conversation.id, channel.id);
    onShowLounge?.call();
  }
}

class _ColumnHeader extends StatelessWidget {
  final Conversation conversation;
  const _ColumnHeader({required this.conversation});

  @override
  Widget build(BuildContext context) {
    final memberCount = conversation.members.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: groupAvatarColor(conversation.id),
            child: Text(
              (conversation.displayName('').isEmpty
                      ? '?'
                      : conversation.displayName(''))
                  .characters
                  .first
                  .toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  conversation.displayName('').isEmpty
                      ? 'Conversation'
                      : conversation.displayName(''),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$memberCount member${memberCount == 1 ? '' : 's'}',
                  style: TextStyle(color: context.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  final String label;
  const _CategoryHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: context.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _TextChannelRow extends StatelessWidget {
  final GroupChannel channel;
  final bool isSelected;
  final VoidCallback onTap;

  const _TextChannelRow({
    required this.channel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'channel ${channel.name}',
      button: true,
      selected: isSelected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: isSelected ? context.accentLight : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.tag,
                    size: 16,
                    color: isSelected ? context.accent : context.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      channel.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected
                            ? context.textPrimary
                            : context.textSecondary,
                        fontSize: 13,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceChannelGroup extends StatelessWidget {
  final GroupChannel channel;
  final List<VoiceSessionMember> members;
  final bool isActive;
  final VoidCallback onJoin;
  final VoidCallback? onOpenLounge;

  const _VoiceChannelGroup({
    required this.channel,
    required this.members,
    required this.isActive,
    required this.onJoin,
    required this.onOpenLounge,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _VoiceChannelRow(
          channel: channel,
          memberCount: members.length,
          isActive: isActive,
          onTap: isActive ? (onOpenLounge ?? onJoin) : onJoin,
        ),
        if (members.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in members)
                  _VoiceMemberRow(member: m, isSelf: false),
              ],
            ),
          ),
      ],
    );
  }
}

class _VoiceChannelRow extends StatelessWidget {
  final GroupChannel channel;
  final int memberCount;
  final bool isActive;
  final VoidCallback onTap;

  const _VoiceChannelRow({
    required this.channel,
    required this.memberCount,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'voice channel ${channel.name}',
      button: true,
      selected: isActive,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: isActive ? context.accentLight : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.volume_up_outlined,
                    size: 16,
                    color: isActive ? context.accent : context.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      channel.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive
                            ? context.textPrimary
                            : context.textSecondary,
                        fontSize: 13,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (memberCount > 0)
                    Text(
                      '$memberCount',
                      style: TextStyle(color: context.textMuted, fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceMemberRow extends StatelessWidget {
  final VoiceSessionMember member;
  final bool isSelf;
  const _VoiceMemberRow({required this.member, required this.isSelf});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          buildAvatar(
            name: member.username,
            radius: 10,
            imageUrl: member.avatarUrl,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              member.username,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
          ),
          if (member.isMuted)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.mic_off_outlined,
                size: 12,
                color: context.textMuted,
              ),
            ),
          if (member.isDeafened)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.headset_off_outlined,
                size: 12,
                color: context.textMuted,
              ),
            ),
        ],
      ),
    );
  }
}
