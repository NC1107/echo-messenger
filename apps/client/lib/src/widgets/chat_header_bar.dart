import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

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
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor, resolveAvatarUrl;
import 'chat_header_widgets.dart';
import 'shared_media_gallery.dart';
import 'window_chrome.dart';

const _disappearingMessagesLabel = 'Disappearing messages';
const _kAuthorizationHeader = 'Authorization';

class ChatHeaderBar extends ConsumerWidget {
  final Conversation conversation;
  final String myUserId;
  final String serverUrl;
  final VoidCallback? onBack;
  final bool showSearch;
  final VoidCallback onToggleSearch;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;

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
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = conversation;
    final displayName = conv.displayName(myUserId);

    final isDesktop =
        !kIsWeb &&
        (Theme.of(context).platform == TargetPlatform.linux ||
            Theme.of(context).platform == TargetPlatform.windows ||
            Theme.of(context).platform == TargetPlatform.macOS);

    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          // Left: draggable region (back button + avatar + name/status).
          // AppDragArea wraps only this passive area so the interactive
          // controls on the right are never inside the drag recogniser.
          Expanded(
            child: AppDragArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Row(
                  children: [
                    if (onBack != null) ...[
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 20),
                        color: context.textSecondary,
                        tooltip: 'Back',
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
                    Expanded(
                      child: _buildNameAndStatus(
                        context,
                        ref,
                        conv,
                        displayName,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Right: non-draggable interactive controls.
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ..._buildActionButtons(context, ref, conv),
                const SizedBox(width: 4),
                const _ConnectionStatusDot(),
                if (isDesktop) const AppWindowButtons(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderAvatar(Conversation conv, String displayName) {
    return Builder(
      builder: (context) {
        String? headerAvatarUrl;
        if (conv.isGroup) {
          headerAvatarUrl = resolveAvatarUrl(conv.iconUrl, serverUrl);
        } else {
          final peer = conv.members
              .where((m) => m.userId != myUserId)
              .firstOrNull;
          headerAvatarUrl = resolveAvatarUrl(peer?.avatarUrl, serverUrl);
        }
        final avatar = buildAvatar(
          name: displayName,
          radius: 16,
          imageUrl: headerAvatarUrl,
          bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
          fallbackIcon: conv.isGroup
              ? Icon(
                  Icons.group,
                  size: 14,
                  color: Theme.of(context).colorScheme.onPrimary,
                )
              : null,
        );
        if (conv.isGroup && onGroupInfo != null) {
          return Semantics(
            label: 'group info',
            button: true,
            child: GestureDetector(onTap: onGroupInfo, child: avatar),
          );
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
    return Semantics(
      label: 'view $displayName details',
      button: true,
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
            _buildNameRow(context, ref, conv, displayName),
            _buildStatusLine(context, ref, conv),
          ],
        ),
      ),
    );
  }

  /// Name row — shows the display name and, for 1:1 conversations, a small
  /// green "verified" check next to the name when the user has previously
  /// confirmed the peer's safety number on this device. Also shows a small
  /// timer chip when disappearing messages are enabled.
  Widget _buildNameRow(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    String displayName,
  ) {
    final nameText = Text(
      displayName,
      style: GoogleFonts.inter(
        color: context.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );

    final ttl = conv.ttlSeconds ?? 0;
    final showTimer = ttl > 0;

    final timerChip = showTimer
        ? TimerChip(
            seconds: ttl,
            onTap: () => _showDisappearingDialog(context, ref, conv),
          )
        : null;

    // For DMs, render an amber lock-open glyph when the conversation is not
    // encrypted (explicit "plaintext DM" warning replaces the old banner).
    // Groups never show the unlock-open glyph because group plaintext is
    // expected today.
    final Widget? lockGlyph = conv.isEncrypted
        ? Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Tooltip(
              message: 'End-to-end encrypted',
              child: Icon(Icons.lock, size: 12, color: context.textMuted),
            ),
          )
        : (!conv.isGroup
              ? const Padding(
                  padding: EdgeInsets.only(left: 5),
                  child: Tooltip(
                    message: 'Not encrypted -- plaintext DM',
                    child: Icon(
                      Icons.lock_open,
                      size: 12,
                      color: EchoTheme.warning,
                    ),
                  ),
                )
              : null);

    if (conv.isGroup) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [nameText, ?lockGlyph, ?timerChip],
      );
    }

    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    if (peer == null) return nameText;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        nameText,
        ?lockGlyph,
        IdentityChangedBadge(peerUserId: peer.userId),
        VerifiedBadge(peerUserId: peer.userId),
        ?timerChip,
      ],
    );
  }

  Widget _buildStatusLine(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    final wsState = ref.watch(websocketProvider);
    if (conv.isGroup) {
      final memberCount = conv.members.length;
      final onlineCount = conv.members
          .where((m) => wsState.isUserOnline(m.userId))
          .length;
      final isNarrow = MediaQuery.of(context).size.width < 500;
      final memberLabel = isNarrow
          ? '$memberCount'
          : '$memberCount member${memberCount == 1 ? '' : 's'}';
      return Text(
        onlineCount > 0 ? '$memberLabel · $onlineCount online' : memberLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(color: context.textMuted, fontSize: 11),
      );
    }
    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    final peerOnline = peer != null && wsState.isUserOnline(peer.userId);
    final lastSeen = peer == null ? null : wsState.lastSeenFor(peer.userId);
    final label = formatPeerStatusLabel(
      isOnline: peerOnline,
      lastSeen: lastSeen,
    );
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.inter(
        color: peerOnline ? EchoTheme.online : context.textMuted,
        fontSize: 11,
      ),
    );
  }

  List<Widget> _buildActionButtons(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    final chatState = ref.watch(chatProvider);
    final pinnedCount = chatState
        .messagesForConversation(conv.id)
        .where((m) => m.pinnedAt != null)
        .length;

    final isNarrow = Responsive.isMobile(context);

    if (isNarrow) {
      return _buildNarrowActionButtons(context, ref, conv, pinnedCount);
    }
    return _buildWideActionButtons(context, ref, conv, pinnedCount);
  }

  /// Narrow layout: voice call + search visible, rest in overflow menu.
  List<Widget> _buildNarrowActionButtons(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    int pinnedCount,
  ) {
    return [
      if (!conv.isGroup)
        IconButton(
          icon: const Icon(Icons.call_outlined, size: 20),
          color: context.textSecondary,
          tooltip: 'Start call',
          onPressed: () => _startVoiceCall(context, ref, conv),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      IconButton(
        icon: Icon(showSearch ? Icons.search_off : Icons.search, size: 20),
        color: showSearch ? context.accent : context.textSecondary,
        tooltip: showSearch ? 'Close search' : 'Search messages',
        onPressed: onToggleSearch,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      ),
      _buildOverflowMenu(context, ref, conv, pinnedCount, isWide: false),
    ];
  }

  /// Overflow 3-dot menu.
  ///
  /// In wide layout the inline action row already exposes pins, search, media,
  /// safety-number (DMs) and members (groups), so the overflow only carries
  /// the advanced actions that don't have inline equivalents. When wide and
  /// no advanced actions apply (e.g. unencrypted group), the menu is hidden
  /// entirely (#738).
  Widget _buildOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    int pinnedCount, {
    required bool isWide,
  }) {
    final items = <PopupMenuEntry<String>>[
      if (!isWide && !conv.isGroup)
        PopupMenuItem<String>(
          value: 'safety',
          child: _overflowItem(
            context,
            icon: Icons.lock_outlined,
            label: 'Verify safety number',
            color: EchoTheme.online,
          ),
        ),
      if (!conv.isGroup && conv.isEncrypted)
        PopupMenuItem<String>(
          value: 'reset_keys',
          child: _overflowItem(
            context,
            icon: Icons.healing,
            label: 'Fix encryption issues',
          ),
        ),
      if (!isWide)
        PopupMenuItem<String>(
          value: 'pins',
          child: _overflowItem(
            context,
            icon: Icons.push_pin_outlined,
            label: pinnedCount > 0
                ? 'Pinned ($pinnedCount)'
                : 'Pinned messages',
          ),
        ),
      if (!isWide)
        PopupMenuItem<String>(
          value: 'media',
          child: _overflowItem(
            context,
            icon: Icons.photo_library_outlined,
            label: 'Shared media',
          ),
        ),
      if (!isWide && conv.isGroup && onMembersToggle != null)
        PopupMenuItem<String>(
          value: 'members',
          child: _overflowItem(
            context,
            icon: Icons.people_outline,
            label: 'Members',
          ),
        ),
      if (!conv.isGroup)
        PopupMenuItem<String>(
          value: 'disappearing',
          child: _overflowItem(
            context,
            icon: Icons.timer_outlined,
            label: _disappearingMessagesLabel,
          ),
        ),
    ];

    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
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
          case 'disappearing':
            _showDisappearingDialog(context, ref, conv);
        }
      },
      itemBuilder: (_) => items,
    );
  }

  /// Wide layout: call, pin, search, media, members inline; advanced actions
  /// (safety number, encryption repair, disappearing timer) in overflow menu.
  List<Widget> _buildWideActionButtons(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    int pinnedCount,
  ) {
    return [
      if (!conv.isGroup)
        IconButton(
          icon: const Icon(Icons.call_outlined, size: 20),
          color: context.textSecondary,
          tooltip: 'Start call',
          onPressed: () => _startVoiceCall(context, ref, conv),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      IconButton(
        icon: const Icon(Icons.push_pin_outlined, size: 20),
        color: context.textSecondary,
        tooltip: 'Pinned messages',
        onPressed: () => _showPinnedMessagesDialog(context, ref, conv),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      ),
      IconButton(
        icon: Icon(showSearch ? Icons.search_off : Icons.search, size: 20),
        color: showSearch ? context.accent : context.textSecondary,
        tooltip: showSearch ? 'Close search' : 'Search messages',
        onPressed: onToggleSearch,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      ),
      IconButton(
        icon: const Icon(Icons.photo_library_outlined, size: 20),
        color: context.textSecondary,
        tooltip: 'Shared media',
        onPressed: () => _openSharedMedia(context, conv),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      ),
      if (!conv.isGroup && conv.isEncrypted)
        IconButton(
          icon: const Icon(Icons.verified_user_outlined, size: 18),
          color: context.textSecondary,
          tooltip: 'Verify encryption',
          onPressed: () => _openSafetyNumber(context, ref, conv),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      if (conv.isGroup && onMembersToggle != null)
        IconButton(
          icon: const Icon(Icons.people_outline, size: 20),
          color: context.textSecondary,
          tooltip: 'Members',
          onPressed: onMembersToggle,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      _buildOverflowMenu(context, ref, conv, pinnedCount, isWide: true),
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
        Text(label, style: GoogleFonts.inter(color: itemColor, fontSize: 13)),
      ],
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

    // Notify peers and add system event to chat timeline
    ref.read(websocketProvider.notifier).sendCallStarted(conv.id);
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

  static const _kTtlOptions = [
    (label: 'Off', seconds: null as int?),
    (label: '30 seconds', seconds: 30 as int?),
    (label: '5 minutes', seconds: 300 as int?),
    (label: '1 hour', seconds: 3600 as int?),
    (label: '1 day', seconds: 86400 as int?),
    (label: '1 week', seconds: 604800 as int?),
  ];

  Future<void> _showDisappearingDialog(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) async {
    final currentTtl = conv.ttlSeconds;
    final selected = await showDialog<int?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(_disappearingMessagesLabel),
        children: _kTtlOptions.map((opt) {
          final isCurrent = opt.seconds == currentTtl;
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(opt.seconds ?? -1),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: isCurrent
                      ? Icon(Icons.check, size: 16, color: ctx.accent)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(opt.label),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected == null || !context.mounted) return;
    // -1 sentinel means "off" (null TTL)
    final ttl = selected < 0 ? null : selected;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.put(
              Uri.parse('$serverUrl/api/conversations/${conv.id}/disappearing'),
              headers: {
                _kAuthorizationHeader: 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'ttl_seconds': ttl}),
            ),
          );
      if (!context.mounted) return;
      if (response.statusCode == 200) {
        ToastService.show(
          context,
          ttl == null
              ? 'Disappearing messages turned off'
              : 'Messages will disappear after ${_kTtlOptions.firstWhere((o) => o.seconds == ttl).label}',
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    } catch (_) {
      if (context.mounted) {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    }
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
      builder: (dialogContext) => PinnedMessagesDialog(
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
          style: GoogleFonts.inter(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will establish a fresh encrypted session. '
          'Messages encrypted with the old keys may become unreadable.',
          style: GoogleFonts.inter(color: context.textSecondary, fontSize: 14),
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

      // Notify the peer so they invalidate their session too
      ref.read(websocketProvider.notifier).sendKeyReset(conv.id);

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

/// Small connection-state indicator rendered in the header actions row.
///
/// Replaces the standalone full-width [ConnectionStatusBanner]. Color codes:
/// green when connected, amber while reconnecting, red after max attempts
/// or session-replaced. Tap to force a reconnect.
class _ConnectionStatusDot extends ConsumerWidget {
  const _ConnectionStatusDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(websocketProvider);
    final maxAttempts = !ws.isConnected && ws.reconnectAttempts >= 10;
    final isError = ws.wasReplaced || maxAttempts;
    final Color color;
    final String tooltip;
    if (ws.isConnected) {
      color = EchoTheme.online;
      tooltip = 'Connected';
    } else if (isError) {
      color = EchoTheme.danger;
      tooltip = ws.wasReplaced
          ? 'Signed in on another device -- tap to reconnect'
          : 'Connection lost -- tap to retry';
    } else {
      color = EchoTheme.warning;
      tooltip = ws.reconnectAttempts > 0
          ? 'Reconnecting (${ws.reconnectAttempts})...'
          : 'Reconnecting...';
    }

    return Semantics(
      label: tooltip,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            final notifier = ref.read(websocketProvider.notifier);
            if (ref.read(websocketProvider).wasReplaced) {
              notifier.reconnectAfterReplacement();
            } else {
              notifier.connect();
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
