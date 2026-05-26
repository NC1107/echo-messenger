import 'dart:convert';

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
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor, resolveAvatarUrl;
import 'chat_header_widgets.dart';
import 'confirm_dialog.dart';
import 'echo_bottom_sheet.dart';
import 'group_members_sheet.dart' show showGroupMembersSheet;
import 'shared_media_gallery.dart';

const _disappearingMessagesLabel = 'Disappearing messages';
const _kAuthorizationHeader = 'Authorization';

class ChatHeaderBar extends ConsumerWidget {
  final Conversation conversation;
  final String myUserId;
  final String serverUrl;
  final VoidCallback? onBack;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;

  /// When true, the group's avatar + name + status are NOT rendered.
  /// Used by Column mode where the channel rail's own header already
  /// shows the group identity (avatar + name + member count), so this
  /// row would duplicate it. The action buttons on the right
  /// (pin / shared media / members) still render. Search lives on
  /// Ctrl+F (#1135).
  final bool hideGroupIdentity;

  const ChatHeaderBar({
    super.key,
    required this.conversation,
    required this.myUserId,
    required this.serverUrl,
    this.onBack,
    this.onMembersToggle,
    this.onGroupInfo,
    this.hideGroupIdentity = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = conversation;
    final displayName = conv.displayName(myUserId);

    return LayoutBuilder(
      builder: (context, constraints) {
        // On narrow portrait (< 400 logical px wide) reduce horizontal padding
        // so the back button + display name don't crowd each other.
        final hPad = constraints.maxWidth < 400 ? 8.0 : 16.0;
        return _buildHeaderRow(context, ref, conv, displayName, hPad);
      },
    );
  }

  Widget _buildHeaderRow(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    String displayName,
    double hPad,
  ) {
    return Container(
      height: 60,
      padding: EdgeInsets.symmetric(horizontal: hPad),
      decoration: BoxDecoration(
        color: context.sidebarBg,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              color: context.textSecondary,
              tooltip: 'Back',
              onPressed: onBack,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
            const SizedBox(width: 4),
          ],
          if (!hideGroupIdentity) ...[
            _buildHeaderAvatar(conv, displayName),
            const SizedBox(width: 12),
            Expanded(
              child: _buildNameAndStatus(context, ref, conv, displayName),
            ),
          ] else
            const Spacer(),
          ..._buildActionButtons(context, ref, conv),
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

    // Plaintext-DM warning glyph; groups skip it (group plaintext is currently expected).
    final Widget? unencryptedDmGlyph = !conv.isGroup
        ? const Padding(
            padding: EdgeInsets.only(left: 5),
            child: Tooltip(
              message: 'Not encrypted -- plaintext DM',
              child: Icon(Icons.lock_open, size: 12, color: EchoTheme.warning),
            ),
          )
        : null;
    final Widget? lockGlyph = conv.isEncrypted
        ? Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Tooltip(
              message: 'End-to-end encrypted',
              child: Icon(Icons.lock, size: 12, color: context.textMuted),
            ),
          )
        : unencryptedDmGlyph;

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
      final memberLabel = '$memberCount member${memberCount == 1 ? '' : 's'}';
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

  /// Narrow layout: voice call (DMs) + members (groups) + search visible;
  /// remaining actions in overflow menu.
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
      if (conv.isGroup)
        IconButton(
          icon: const Icon(Icons.people_outline, size: 20),
          color: context.textSecondary,
          tooltip: 'Members',
          onPressed: () => showGroupMembersSheet(context, conv),
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
      // Members lives as an inline icon (narrow + wide layouts); no overflow entry needed.
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
      _PinnedMessagesIconButton(
        pinnedCount: pinnedCount,
        onPressed: () => _showPinnedMessagesDialog(context, ref, conv),
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
    // Wide viewports (>= 900px) get a centred dialog; narrow stays on bottom sheet.
    final screen = MediaQuery.of(context).size;
    if (screen.width >= 900) {
      showDialog<void>(
        context: context,
        builder: (dialogCtx) {
          final size = MediaQuery.of(dialogCtx).size;
          final width = size.width.clamp(720.0, 1200.0).toDouble();
          final height = (size.height * 0.85).clamp(520.0, 900.0).toDouble();
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(EchoSpacing.xl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              child: SizedBox(
                width: width,
                height: height,
                child: SharedMediaGallery(conversationId: conv.id),
              ),
            ),
          );
        },
      );
      return;
    }
    showEchoBottomSheet<void>(
      context,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: SharedMediaGallery(conversationId: conv.id),
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

    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Reset encryption keys?',
      content:
          'This will establish a fresh encrypted session. '
          'Messages encrypted with the old keys may become unreadable.',
      confirmLabel: 'Reset Keys',
      destructive: true,
    );

    if (!confirmed) return;

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

/// Pinned-messages action button with an inline numeric badge.
///
/// Mirrors the visual language of the conversation list's unread-count
/// badge: top-right anchor, accent fill, white-on-accent text, "99+" cap.
/// Falls through to a plain [IconButton] when there are no pinned messages.
class _PinnedMessagesIconButton extends StatelessWidget {
  final int pinnedCount;
  final VoidCallback onPressed;

  const _PinnedMessagesIconButton({
    required this.pinnedCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final tooltip = pinnedCount > 0
        ? 'Pinned messages ($pinnedCount)'
        : 'Pinned messages';
    final button = IconButton(
      icon: const Icon(Icons.push_pin_outlined, size: 20),
      color: context.textSecondary,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );

    if (pinnedCount <= 0) return button;

    final label = pinnedCount > 99 ? '99+' : '$pinnedCount';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        Positioned(
          top: 6,
          right: 4,
          child: IgnorePointer(
            child: Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: context.accent,
                shape: BoxShape.rectangle,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: GoogleFonts.inter(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
