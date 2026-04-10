import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/safety_number_screen.dart';
import '../screens/user_profile_screen.dart';
import '../providers/livekit_voice_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor;
import 'shared_media_gallery.dart';

class ChatHeaderBar extends ConsumerWidget {
  final Conversation conversation;
  final String myUserId;
  final String serverUrl;
  final VoidCallback? onBack;
  final bool showSearch;
  final VoidCallback onToggleSearch;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final VoidCallback onDismissEncryptionBanner;
  final bool hideEncryptionBanner;

  const ChatHeaderBar({
    super.key,
    required this.conversation,
    required this.myUserId,
    required this.serverUrl,
    this.onBack,
    required this.showSearch,
    required this.onToggleSearch,
    this.onMembersToggle,
    this.onGroupInfo,
    required this.onDismissEncryptionBanner,
    this.hideEncryptionBanner = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = conversation;
    final displayName = conv.displayName(myUserId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: context.chatBg,
            border: Border(bottom: BorderSide(color: context.border, width: 1)),
          ),
          child: Row(
            children: [
              if (onBack != null) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  color: context.textSecondary,
                  onPressed: onBack,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              _buildHeaderAvatar(conv, displayName),
              const SizedBox(width: 12),
              _buildNameAndStatus(context, ref, conv, displayName),
              ..._buildActionButtons(context, ref, conv),
            ],
          ),
        ),
        _buildEncryptionBanner(
          context,
          conv.isGroup,
          isEncrypted: conv.isEncrypted,
        ),
      ],
    );
  }

  Widget _buildHeaderAvatar(Conversation conv, String displayName) {
    return Builder(
      builder: (context) {
        String? headerAvatarUrl;
        if (!conv.isGroup) {
          final peer = conv.members
              .where((m) => m.userId != myUserId)
              .firstOrNull;
          if (peer?.avatarUrl != null) {
            headerAvatarUrl = '$serverUrl${peer!.avatarUrl}';
          }
        }
        final avatar = buildAvatar(
          name: displayName,
          radius: 16,
          imageUrl: headerAvatarUrl,
          bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
          fallbackIcon: conv.isGroup
              ? const Icon(Icons.group, size: 14, color: Colors.white)
              : null,
        );
        if (conv.isGroup && onGroupInfo != null) {
          return GestureDetector(onTap: onGroupInfo, child: avatar);
        }
        return avatar;
      },
    );
  }

  Widget _buildNameAndStatus(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    String displayName,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: conv.isGroup
            ? onGroupInfo
            : () {
                final peer = conv.members
                    .where((m) => m.userId != myUserId)
                    .firstOrNull;
                if (peer != null) {
                  UserProfileScreen.show(context, ref, peer.userId);
                }
              },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              displayName,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            _buildStatusLine(context, ref, conv),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusLine(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    if (conv.isGroup) {
      final memberCount = conv.members.length;
      return Text(
        '$memberCount member${memberCount == 1 ? '' : 's'}',
        style: TextStyle(color: context.textMuted, fontSize: 12),
      );
    }
    final wsState = ref.watch(websocketProvider);
    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    final peerOnline = peer != null && wsState.isUserOnline(peer.userId);
    return Text(
      peerOnline ? 'Online' : 'Offline',
      style: TextStyle(
        color: peerOnline ? EchoTheme.online : context.textMuted,
        fontSize: 12,
      ),
    );
  }

  List<Widget> _buildActionButtons(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    // Count pinned messages from local state.
    final chatState = ref.watch(chatProvider);
    final pinnedCount = chatState
        .messagesForConversation(conv.id)
        .where((m) => m.pinnedAt != null)
        .length;

    // On narrow screens (< 600 px) keep only voice call + search always
    // visible and move the rest into a 3-dot overflow menu.
    final isNarrow = Responsive.isMobile(context);

    if (isNarrow) {
      return [
        // Voice call always visible (DM only)
        if (!conv.isGroup)
          IconButton(
            icon: const Icon(Icons.call_outlined, size: 20),
            color: context.textSecondary,
            tooltip: 'Start call',
            onPressed: () => _startVoiceCall(context, ref, conv),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        // Search always visible
        IconButton(
          icon: Icon(showSearch ? Icons.search_off : Icons.search, size: 20),
          color: showSearch ? context.accent : context.textSecondary,
          tooltip: showSearch ? 'Close search' : 'Search messages',
          onPressed: onToggleSearch,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
        // Overflow menu
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, size: 20, color: context.textSecondary),
          tooltip: 'More options',
          color: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: context.border),
          ),
          onSelected: (value) {
            switch (value) {
              case 'safety':
                _openSafetyNumber(context, ref, conv);
              case 'reset_keys':
                _resetPeerKeys(context, ref, conv, myUserId);
              case 'pins':
                _showPinnedMessagesDialog(context, ref, conv);
              case 'media':
                _openSharedMedia(context, conv);
              case 'members':
                onMembersToggle?.call();
            }
          },
          itemBuilder: (ctx) => [
            if (!conv.isGroup)
              PopupMenuItem<String>(
                value: 'safety',
                child: _overflowItem(
                  ctx,
                  icon: Icons.lock_outlined,
                  label: 'Verify safety number',
                  color: EchoTheme.online,
                ),
              ),
            if (!conv.isGroup && conv.isEncrypted)
              PopupMenuItem<String>(
                value: 'reset_keys',
                child: _overflowItem(
                  ctx,
                  icon: Icons.vpn_key_off,
                  label: 'Reset encryption keys',
                ),
              ),
            PopupMenuItem<String>(
              value: 'pins',
              child: _overflowItem(
                ctx,
                icon: Icons.push_pin_outlined,
                label: pinnedCount > 0
                    ? 'Pinned ($pinnedCount)'
                    : 'Pinned messages',
              ),
            ),
            PopupMenuItem<String>(
              value: 'media',
              child: _overflowItem(
                ctx,
                icon: Icons.photo_library_outlined,
                label: 'Shared media',
              ),
            ),
            if (conv.isGroup && onMembersToggle != null)
              PopupMenuItem<String>(
                value: 'members',
                child: _overflowItem(
                  ctx,
                  icon: Icons.people_outline,
                  label: 'Members',
                ),
              ),
          ],
        ),
      ];
    }

    // Wide layout: show all buttons inline (existing behaviour).
    return [
      if (!conv.isGroup)
        IconButton(
          icon: const Icon(Icons.lock_outlined, size: 20),
          color: EchoTheme.online,
          tooltip: 'Verify safety number',
          onPressed: () => _openSafetyNumber(context, ref, conv),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      if (!conv.isGroup && conv.isEncrypted)
        IconButton(
          icon: const Icon(Icons.vpn_key_off, size: 18),
          color: context.textMuted,
          tooltip: 'Reset encryption keys',
          onPressed: () => _resetPeerKeys(context, ref, conv, myUserId),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      // Voice call button (DM only — groups have voice channel chips)
      if (!conv.isGroup)
        IconButton(
          icon: const Icon(Icons.call_outlined, size: 20),
          color: context.textSecondary,
          tooltip: 'Start call',
          onPressed: () => _startVoiceCall(context, ref, conv),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      IconButton(
        icon: Badge(
          isLabelVisible: pinnedCount > 0,
          label: Text(
            '$pinnedCount',
            style: const TextStyle(fontSize: 9, color: Colors.white),
          ),
          backgroundColor: context.accent,
          child: const Icon(Icons.push_pin_outlined, size: 20),
        ),
        color: context.textSecondary,
        tooltip: 'Pinned messages',
        onPressed: () => _showPinnedMessagesDialog(context, ref, conv),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
      IconButton(
        icon: Icon(showSearch ? Icons.search_off : Icons.search, size: 20),
        color: showSearch ? context.accent : context.textSecondary,
        tooltip: showSearch ? 'Close search' : 'Search messages',
        onPressed: onToggleSearch,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
      IconButton(
        icon: const Icon(Icons.photo_library_outlined, size: 20),
        color: context.textSecondary,
        tooltip: 'Shared media',
        onPressed: () => _openSharedMedia(context, conv),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
      if (conv.isGroup) ...[
        if (onMembersToggle != null)
          IconButton(
            icon: const Icon(Icons.people_outline, size: 20),
            color: context.textSecondary,
            tooltip: 'Members',
            onPressed: onMembersToggle,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
      ],
    ];
  }

  /// Helper to build a consistent icon + label row for overflow menu items.
  Widget _overflowItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final itemColor = color ?? context.textPrimary;
    return Row(
      children: [
        Icon(icon, size: 18, color: itemColor),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: itemColor, fontSize: 13)),
      ],
    );
  }

  Widget _buildEncryptionBanner(
    BuildContext context,
    bool isGroup, {
    bool isEncrypted = false,
  }) {
    // Encryption banner removed — status shown via lock icon in header instead.
    // Only show banner for unencrypted DMs as a warning.
    if (hideEncryptionBanner || isGroup || isEncrypted) {
      return const SizedBox.shrink();
    }

    const label = 'Encryption is off — messages are sent as plaintext';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border.all(color: EchoTheme.warning.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_open_outlined,
            size: 14,
            color: EchoTheme.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: EchoTheme.warning),
            ),
          ),
          GestureDetector(
            onTap: onDismissEncryptionBanner,
            child: Icon(Icons.close, size: 14, color: context.textMuted),
          ),
        ],
      ),
    );
  }

  void _openSharedMedia(BuildContext context, Conversation conv) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: SharedMediaGallery(conversationId: conv.id),
        ),
      ),
    );
  }

  void _startVoiceCall(BuildContext context, WidgetRef ref, Conversation conv) {
    final voiceState = ref.read(livekitVoiceProvider);
    if (voiceState.isActive) {
      // Already in a call — show info
      ToastService.show(
        context,
        'Already in a voice call.',
        type: ToastType.info,
      );
      return;
    }

    ref
        .read(livekitVoiceProvider.notifier)
        .joinChannel(conversationId: conv.id, channelId: conv.id);

    // Add system event to chat timeline
    ref
        .read(chatProvider.notifier)
        .addSystemEvent(conv.id, 'Voice call started');
  }

  void _openSafetyNumber(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    if (peer == null) return;

    final authState = ref.read(authProvider);
    final myName = authState.username ?? 'You';

    SafetyNumberScreen.show(
      context,
      ref,
      peerUserId: peer.userId,
      peerUsername: peer.username,
      myUsername: myName,
    );
  }

  void _showPinnedMessagesDialog(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    final serverUrl = ref.read(serverUrlProvider);
    final myUserId = this.myUserId;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => _PinnedMessagesDialog(
        conversationId: conv.id,
        serverUrl: serverUrl,
        myUserId: myUserId,
      ),
    );
  }

  Future<void> _resetPeerKeys(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    String myId,
  ) async {
    final peerId = conv.members
        .where((m) => m.userId != myId)
        .firstOrNull
        ?.userId;
    if (peerId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Reset encryption keys?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will establish a fresh encrypted session. '
          'Messages encrypted with the old keys may become unreadable.',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Reset Keys'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final crypto = ref.read(cryptoServiceProvider);
      crypto.setToken(ref.read(authProvider).token ?? '');
      await crypto.invalidateSessionKey(peerId);

      // Add system event to chat timeline
      ref
          .read(chatProvider.notifier)
          .addSystemEvent(
            conv.id,
            'Encryption keys reset — next message will establish new session',
          );

      if (context.mounted) {
        ToastService.show(
          context,
          'Encryption keys reset. Next message will establish new session.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (context.mounted) {
        ToastService.show(
          context,
          'Failed to reset keys: $e',
          type: ToastType.error,
        );
      }
    }
  }
}

/// Dialog that fetches and displays pinned messages for a conversation.
class _PinnedMessagesDialog extends ConsumerStatefulWidget {
  final String conversationId;
  final String serverUrl;
  final String myUserId;

  const _PinnedMessagesDialog({
    required this.conversationId,
    required this.serverUrl,
    required this.myUserId,
  });

  @override
  ConsumerState<_PinnedMessagesDialog> createState() =>
      _PinnedMessagesDialogState();
}

class _PinnedMessagesDialogState extends ConsumerState<_PinnedMessagesDialog> {
  List<ChatMessage>? _pinnedMessages;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchPinnedMessages();
  }

  Future<void> _fetchPinnedMessages() async {
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '${widget.serverUrl}/api/conversations'
                '/${widget.conversationId}/pinned',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        final list = decoded is List
            ? decoded
            : (decoded['messages'] as List? ?? []);
        final messages = list
            .map(
              (e) => ChatMessage.fromServerJson(
                e as Map<String, dynamic>,
                widget.myUserId,
              ),
            )
            .toList();
        setState(() {
          _pinnedMessages = messages;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load pinned messages';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load pinned messages';
        _isLoading = false;
      });
    }
  }

  Future<void> _unpinMessage(ChatMessage message) async {
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse(
                '${widget.serverUrl}/api/conversations'
                '/${widget.conversationId}'
                '/messages/${message.id}/pin',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        ref
            .read(chatProvider.notifier)
            .updateMessagePin(widget.conversationId, message.id, null, null);
        setState(() {
          _pinnedMessages?.removeWhere((m) => m.id == message.id);
        });
        ToastService.show(context, 'Message unpinned', type: ToastType.success);
      } else {
        ToastService.show(
          context,
          'Failed to unpin message',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Failed to unpin message',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.border),
      ),
      title: Row(
        children: [
          Icon(Icons.push_pin, size: 18, color: context.accent),
          const SizedBox(width: 8),
          Text(
            'Pinned Messages',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: SizedBox(width: 420, height: 380, child: _buildContent(context)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
      );
    }
    final messages = _pinnedMessages ?? [];
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.push_pin_outlined, size: 40, color: context.textMuted),
            const SizedBox(height: 12),
            Text(
              'No pinned messages',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: messages.length,
      separatorBuilder: (_, _) => Divider(color: context.border, height: 1),
      itemBuilder: (_, index) {
        final msg = messages[index];
        final preview = msg.content.length > 120
            ? '${msg.content.substring(0, 120)}...'
            : msg.content;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fromUsername,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMessageTimestamp(msg.timestamp),
                      style: TextStyle(fontSize: 11, color: context.textMuted),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.push_pin_outlined, size: 16),
                color: context.textMuted,
                tooltip: 'Unpin',
                onPressed: () => _unpinMessage(msg),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        );
      },
    );
  }
}
