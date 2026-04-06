import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'conversation_panel.dart' show buildAvatar, groupAvatarColor;

class ChatHeaderBar extends ConsumerWidget {
  final Conversation conversation;
  final String myUserId;
  final String serverUrl;
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
      builder: (_) {
        String? headerAvatarUrl;
        if (!conv.isGroup) {
          final peer = conv.members
              .where((m) => m.userId != myUserId)
              .firstOrNull;
          if (peer?.avatarUrl != null) {
            headerAvatarUrl = '$serverUrl${peer!.avatarUrl}';
          }
        }
        return buildAvatar(
          name: displayName,
          radius: 16,
          imageUrl: headerAvatarUrl,
          bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
          fallbackIcon: conv.isGroup
              ? const Icon(Icons.group, size: 14, color: Colors.white)
              : null,
        );
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
        onTap: !conv.isGroup
            ? () {
                final peer = conv.members
                    .where((m) => m.userId != myUserId)
                    .firstOrNull;
                if (peer != null) {
                  UserProfileScreen.show(context, ref, peer.userId);
                }
              }
            : null,
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
    return [
      if (!conv.isGroup)
        const Tooltip(
          message: 'End-to-end encrypted',
          child: Icon(Icons.lock_outlined, size: 20, color: EchoTheme.online),
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
      IconButton(
        icon: Icon(showSearch ? Icons.search_off : Icons.search, size: 20),
        color: showSearch ? context.accent : context.textSecondary,
        tooltip: showSearch ? 'Close search' : 'Search messages',
        onPressed: onToggleSearch,
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
        IconButton(
          icon: const Icon(Icons.info_outline, size: 20),
          color: context.textSecondary,
          tooltip: 'Group Info',
          onPressed: onGroupInfo,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    ];
  }

  Widget _buildEncryptionBanner(
    BuildContext context,
    bool isGroup, {
    bool isEncrypted = false,
  }) {
    if (hideEncryptionBanner) {
      return const SizedBox.shrink();
    }

    final encrypted = !isGroup && isEncrypted;
    final String label;
    if (isGroup) {
      label = 'Group messages are not encrypted';
    } else if (isEncrypted) {
      label = 'Messages are end-to-end encrypted';
    } else {
      label = 'Encryption is off -- messages are sent as plaintext';
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border.all(
          color: encrypted
              ? EchoTheme.online.withValues(alpha: 0.45)
              : context.border,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            encrypted ? Icons.lock_outlined : Icons.lock_open_outlined,
            size: 14,
            color: encrypted ? EchoTheme.online : context.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: encrypted ? 12 : 11,
                color: encrypted ? EchoTheme.online : context.textMuted,
              ),
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
