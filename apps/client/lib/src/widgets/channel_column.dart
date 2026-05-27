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
///
/// The right edge is a draggable resize handle; the chosen width is
/// persisted via [channelColumnWidthProvider]. Right-clicking the rail
/// body surfaces a context menu for creating new text/voice channels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/channel.dart';
import '../models/conversation.dart';
import '../providers/channel_categories_provider.dart';
import '../providers/channel_column_width_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../services/debug_log_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor;

const String _kTextCategoryKey = 'text';
const String _kVoiceCategoryKey = 'voice';

class ChannelColumn extends ConsumerStatefulWidget {
  final Conversation conversation;
  final String? selectedTextChannelId;
  final ValueChanged<String?> onTextChannelChanged;
  final VoidCallback? onShowLounge;

  /// Legacy fixed-width constant kept for the mobile drawer which still
  /// needs a known column width to size its parent Row. The desktop
  /// rail no longer uses this — see [channelColumnWidthProvider].
  static const double width = channelColumnDefaultWidth;

  const ChannelColumn({
    super.key,
    required this.conversation,
    required this.selectedTextChannelId,
    required this.onTextChannelChanged,
    this.onShowLounge,
  });

  @override
  ConsumerState<ChannelColumn> createState() => _ChannelColumnState();
}

class _ChannelColumnState extends ConsumerState<ChannelColumn> {
  /// Width while a drag is in progress. Kept in widget state so the rail
  /// follows the cursor at full frame rate without writing through to
  /// SharedPreferences on every onHorizontalDragUpdate. Committed to the
  /// provider on drag end.
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final channelsState = ref.watch(channelsProvider);
    // channelsFor() can return an unmodifiable view backed by the state's
    // internal map (e.g. when the conversation has no channels yet, an
    // empty const list comes back). Sorting in-place crashes with
    // "Cannot modify an unmodifiable list" on the next build. Copy first.
    final channels = List.of(channelsState.channelsFor(widget.conversation.id))
      ..sort((a, b) => a.position.compareTo(b.position));
    final textChannels = channels.where((c) => c.isText).toList();
    final voiceChannels = channels.where((c) => c.isVoice).toList();
    final voiceState = ref.watch(livekitVoiceProvider);
    final collapsed = ref.watch(channelCategoryCollapsedProvider);
    final textCollapsed = collapsed.contains(_kTextCategoryKey);
    final voiceCollapsed = collapsed.contains(_kVoiceCategoryKey);
    final storedWidth = ref.watch(channelColumnWidthProvider);
    final effectiveWidth = _dragWidth ?? storedWidth;

    final rail = Container(
      width: effectiveWidth,
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(right: BorderSide(color: context.border)),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (details) => _showCreateMenu(details.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ColumnHeader(conversation: widget.conversation),
            Divider(height: 1, color: context.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (textChannels.isNotEmpty) ...[
                    _CategoryHeader(
                      label: 'Text Channels',
                      collapsed: textCollapsed,
                      onToggle: () => ref
                          .read(channelCategoryCollapsedProvider.notifier)
                          .toggle(_kTextCategoryKey),
                      onCreate: () => _createChannel('text'),
                    ),
                    if (!textCollapsed)
                      for (final c in textChannels)
                        _TextChannelRow(
                          channel: c,
                          isSelected: c.id == widget.selectedTextChannelId,
                          onTap: () => widget.onTextChannelChanged(c.id),
                        ),
                    const SizedBox(height: 12),
                  ],
                  if (voiceChannels.isNotEmpty) ...[
                    _CategoryHeader(
                      label: 'Voice Channels',
                      collapsed: voiceCollapsed,
                      onToggle: () => ref
                          .read(channelCategoryCollapsedProvider.notifier)
                          .toggle(_kVoiceCategoryKey),
                      onCreate: () => _createChannel('voice'),
                    ),
                    if (!voiceCollapsed)
                      for (final c in voiceChannels)
                        _VoiceChannelGroup(
                          channel: c,
                          members: channelsState.voiceSessionsFor(c.id),
                          isActive:
                              voiceState.channelId == c.id &&
                              voiceState.conversationId ==
                                  widget.conversation.id,
                          onJoin: () => _join(c),
                          onOpenLounge: widget.onShowLounge,
                        ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        rail,
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 6,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _dragWidth = ((_dragWidth ?? storedWidth) + details.delta.dx)
                      .clamp(channelColumnMinWidth, channelColumnMaxWidth);
                });
              },
              onHorizontalDragEnd: (_) {
                final committed = _dragWidth;
                _dragWidth = null;
                if (committed != null) {
                  ref
                      .read(channelColumnWidthProvider.notifier)
                      .setWidth(committed);
                }
              },
              onHorizontalDragCancel: () => setState(() => _dragWidth = null),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _join(GroupChannel channel) async {
    // Two-step join (mirrors channel_bar's `_handleVoiceChipTap`): server membership POST then LiveKit connect — skipping step 2 leaves voiceActive false and the lounge refuses to render.
    DebugLogService.instance.log(
      LogLevel.info,
      'VoiceLoungeUI',
      'voice channel selected (column): ${channel.name} id=${channel.id}',
    );
    final success = await ref
        .read(channelsProvider.notifier)
        .joinVoiceChannel(widget.conversation.id, channel.id);
    if (!success) return;

    final voiceSettings = ref.read(voiceSettingsProvider);
    await ref
        .read(livekitVoiceProvider.notifier)
        .joinChannel(
          conversationId: widget.conversation.id,
          channelId: channel.id,
          startMuted: voiceSettings.selfMuted || voiceSettings.selfDeafened,
        );
    widget.onShowLounge?.call();
  }

  Future<void> _showCreateMenu(Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'text',
          child: ListTile(
            leading: Icon(Icons.tag, size: 18),
            title: Text('New text channel'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'voice',
          child: ListTile(
            leading: Icon(Icons.volume_up_outlined, size: 18),
            title: Text('New voice channel'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    await _createChannel(choice);
  }

  Future<void> _createChannel(String kind) async {
    final name = await _promptChannelName(kind);
    if (name == null || name.isEmpty || !mounted) return;
    final success = await ref
        .read(channelsProvider.notifier)
        .createChannel(widget.conversation.id, name, kind);
    if (!mounted) return;
    if (success) {
      ToastService.show(
        context,
        kind == 'voice'
            ? 'Voice channel "$name" created'
            : 'Channel #$name created',
        type: ToastType.success,
      );
    } else {
      ToastService.show(
        context,
        'Could not create channel',
        type: ToastType.error,
      );
    }
  }

  Future<String?> _promptChannelName(String kind) {
    final controller = TextEditingController();
    final title = kind == 'voice' ? 'New voice channel' : 'New text channel';
    final hint = kind == 'voice' ? 'lounge' : 'general';
    return showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: context.surface,
          title: Text(title, style: TextStyle(color: context.textPrimary)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(
                kind == 'voice' ? Icons.volume_up_outlined : Icons.tag,
                size: 18,
              ),
            ),
            onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogCtx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
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
  final bool collapsed;
  final VoidCallback onToggle;

  /// Optional inline "+" button to create a channel in this category.
  /// Mirrors the right-click menu surface so users who don't think to
  /// right-click can still discover the action.
  final VoidCallback? onCreate;

  const _CategoryHeader({
    required this.label,
    required this.collapsed,
    required this.onToggle,
    this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label category, ${collapsed ? "collapsed" : "expanded"}',
      button: true,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 6),
          child: Row(
            children: [
              Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 14,
                color: context.textMuted,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (onCreate != null)
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: onCreate,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.add, size: 14, color: context.textMuted),
                  ),
                ),
            ],
          ),
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
