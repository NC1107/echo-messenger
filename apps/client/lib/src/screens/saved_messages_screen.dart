import 'package:flutter/material.dart';

import '../services/saved_messages_service.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';

/// Displays all bookmarked messages in a scrollable list.
///
/// Each item shows the sender, conversation, timestamp, and a preview of the
/// message content. The screen can be shown inline (dialog) or pushed onto the
/// navigation stack.
class SavedMessagesScreen extends StatefulWidget {
  /// Optional callback invoked when the user taps a saved message.
  /// Receives [conversationId] and [messageId] so the caller can navigate
  /// to the chat and scroll to the specific message.
  final void Function(String conversationId, String messageId)?
  onNavigateToConversation;

  const SavedMessagesScreen({super.key, this.onNavigateToConversation});

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  List<SavedMessage> _items = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _items = SavedMessagesService.instance.getSavedMessages();
    });
  }

  Future<void> _unsave(String messageId) async {
    await SavedMessagesService.instance.unsaveMessage(messageId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.chatBg,
      appBar: AppBar(
        backgroundColor: context.surface,
        elevation: 0,
        title: Text(
          'Saved Messages',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: IconThemeData(color: context.textSecondary),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: context.border),
        ),
      ),
      body: _items.isEmpty ? _buildEmpty(context) : _buildList(context),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_border_outlined,
              size: 56,
              color: context.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              'No saved messages',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bookmark messages to access them later. '
              'Long-press any message and tap Save.',
              style: TextStyle(fontSize: 14, color: context.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: context.border, indent: 16, endIndent: 16),
      itemBuilder: (context, index) {
        final saved = _items[index];
        final msg = saved.message;
        return _SavedMessageTile(
          saved: saved,
          onTap: widget.onNavigateToConversation != null
              ? () =>
                    widget.onNavigateToConversation!(msg.conversationId, msg.id)
              : null,
          onUnsave: () => _unsave(msg.id),
        );
      },
    );
  }
}

class _SavedMessageTile extends StatelessWidget {
  final SavedMessage saved;
  final VoidCallback? onTap;
  final VoidCallback onUnsave;

  const _SavedMessageTile({
    required this.saved,
    required this.onTap,
    required this.onUnsave,
  });

  /// Derive a display-friendly conversation name.
  ///
  /// The message stores a raw conversation UUID in [ChatMessage.conversationId].
  /// We also check [ChatMessage.fromUsername] as a hint for DMs.
  String _conversationLabel() {
    // If there is a channel, prefer that identifier.
    final channel = saved.message.channelId;
    if (channel != null && channel.isNotEmpty) return '#$channel';
    // Fall back to sender name for DMs.
    return saved.message.fromUsername;
  }

  @override
  Widget build(BuildContext context) {
    final msg = saved.message;
    final ts = formatConversationTimestamp(msg.timestamp);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bookmark icon indicator
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(Icons.bookmark, size: 18, color: context.accent),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: sender + conversation + timestamp
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          msg.fromUsername,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'in ${_conversationLabel()}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      Text(
                        ts,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Message preview
                  Text(
                    msg.content,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.textSecondary,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Unsave button
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Tooltip(
                message: 'Remove bookmark',
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: onUnsave,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.bookmark_remove_outlined,
                      size: 18,
                      color: context.textMuted,
                    ),
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
