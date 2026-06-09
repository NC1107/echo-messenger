// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Channels block: list of text/voice channels for the group, add-channel
/// dialog, delete-channel confirm + provider plumbing.
extension _ChannelsSection on _GroupInfoScreenState {
  Future<void> _showAddChannelDialog() async {
    final result = await showCreateChannelDialog(context);
    if (result == null || !mounted) return;

    final success = await ref
        .read(channelsProvider.notifier)
        .createChannel(widget.conversationId, result.name, result.kind);
    if (mounted) {
      ToastService.show(
        context,
        success ? 'Channel created' : 'Failed to create channel',
        type: success ? ToastType.success : ToastType.error,
      );
    }
  }

  Future<void> _deleteChannel(String channelId, String channelName) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Delete Channel',
      content: 'Delete channel "$channelName"? This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;

    final success = await ref
        .read(channelsProvider.notifier)
        .deleteChannel(widget.conversationId, channelId);
    if (mounted) {
      ToastService.show(
        context,
        success ? 'Channel deleted' : 'Failed to delete channel',
        type: success ? ToastType.success : ToastType.error,
      );
    }
  }

  List<Widget> _buildChannelsSection() {
    return [
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            Text(
              'Channels',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add_outlined),
              tooltip: 'Add channel',
              onPressed: _showAddChannelDialog,
            ),
          ],
        ),
      ),
      _buildChannelsList(),
    ];
  }

  Widget _buildChannelsList() {
    final channelsState = ref.watch(channelsProvider);
    final channels = channelsState.channelsFor(widget.conversationId);
    if (channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          channelsState.isLoadingConversation(widget.conversationId)
              ? 'Loading channels...'
              : 'No channels',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: channels.map((channel) {
        final isDivider = channel.isDivider;
        return ListTile(
          leading: Icon(
            isDivider
                ? Icons.more_vert
                : (channel.isText ? Icons.tag : Icons.headset_mic_outlined),
            size: 20,
          ),
          title: Text(isDivider ? 'Divider' : channel.name),
          subtitle: isDivider ? null : Text(channel.kind),
          trailing: IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
            tooltip: isDivider ? 'Delete divider' : 'Delete channel',
            onPressed: () => _deleteChannel(
              channel.id,
              isDivider ? 'this divider' : channel.name,
            ),
          ),
        );
      }).toList(),
    );
  }
}
