import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor, resolveAvatarUrl;
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
        _buildCorruptionBanner(context, ref, conv),
      ],
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
              ? const Icon(Icons.group, size: 14, color: Colors.white)
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
    return Expanded(
      child: Semantics(
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
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );

    final ttl = conv.ttlSeconds ?? 0;
    final showTimer = ttl > 0;

    final timerChip = showTimer
        ? _TimerChip(
            seconds: ttl,
            onTap: () => _showDisappearingDialog(context, ref, conv),
          )
        : null;

    if (conv.isGroup) {
      if (timerChip == null) return nameText;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [nameText, timerChip],
      );
    }

    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    if (peer == null) return nameText;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        nameText,
        _VerifiedBadge(peerUserId: peer.userId),
        ?timerChip,
      ],
    );
  }

  Widget _buildStatusLine(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    if (conv.isGroup) {
      final memberCount = conv.members.length;
      // On narrow screens show "N" only (no "members" label) so the
      // header subtitle never overflows into the action buttons.
      final isNarrow = MediaQuery.of(context).size.width < 500;
      return Text(
        isNarrow
            ? '$memberCount m'
            : '$memberCount member${memberCount == 1 ? '' : 's'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
      _buildOverflowMenu(context, ref, conv, pinnedCount),
    ];
  }

  /// Overflow 3-dot menu for narrow layouts.
  Widget _buildOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
    int pinnedCount,
  ) {
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
              icon: Icons.healing,
              label: 'Fix encryption issues',
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
        if (!conv.isGroup)
          PopupMenuItem<String>(
            value: 'disappearing',
            child: _overflowItem(
              ctx,
              icon: Icons.timer_outlined,
              label: 'Disappearing messages',
            ),
          ),
      ],
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
      _buildOverflowMenu(context, ref, conv, pinnedCount),
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
          const Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: EchoTheme.warning),
            ),
          ),
          Semantics(
            label: 'dismiss encryption banner',
            button: true,
            child: GestureDetector(
              onTap: onDismissEncryptionBanner,
              child: Icon(Icons.close, size: 14, color: context.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// Show a warning banner when the peer's session is corrupted, with a
  /// one-tap repair action.
  Widget _buildCorruptionBanner(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) {
    if (conv.isGroup) return const SizedBox.shrink();

    final peerId = conv.members
        .where((m) => m.userId != myUserId)
        .firstOrNull
        ?.userId;
    if (peerId == null) return const SizedBox.shrink();

    final crypto = ref.watch(cryptoServiceProvider);
    if (!crypto.isInitialized || !crypto.hasCorruptedSession(peerId)) {
      return const SizedBox.shrink();
    }

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
          const Icon(Icons.warning_amber, size: 14, color: EchoTheme.warning),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Encryption issues detected',
              style: TextStyle(fontSize: 11, color: EchoTheme.warning),
            ),
          ),
          Semantics(
            label: 'reset encryption keys',
            button: true,
            child: GestureDetector(
              onTap: () => _resetPeerKeys(context, ref, conv, myUserId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: EchoTheme.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: EchoTheme.warning.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Repair',
                  style: TextStyle(
                    fontSize: 11,
                    color: EchoTheme.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
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
        title: const Text('Disappearing messages'),
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
                'Authorization': 'Bearer $token',
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

/// Tiny green check shown next to a DM peer's name when the user has
/// previously verified their safety number. Reads `echo_safety_verified_<id>`
/// from SharedPreferences. Clears itself if the pref changes between rebuilds
/// (see IdentityKeyChangedBanner which removes the pref on TOFU).
class _VerifiedBadge extends StatefulWidget {
  final String peerUserId;

  const _VerifiedBadge({required this.peerUserId});

  @override
  State<_VerifiedBadge> createState() => _VerifiedBadgeState();
}

class _VerifiedBadgeState extends State<_VerifiedBadge> {
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _loadVerified();
  }

  @override
  void didUpdateWidget(covariant _VerifiedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerUserId != widget.peerUserId) {
      setState(() => _verified = false);
      _loadVerified();
    }
  }

  Future<void> _loadVerified() async {
    final prefs = await SharedPreferences.getInstance();
    final flag =
        prefs.getBool('echo_safety_verified_${widget.peerUserId}') ?? false;
    if (!mounted) return;
    if (flag != _verified) setState(() => _verified = flag);
  }

  @override
  Widget build(BuildContext context) {
    if (!_verified) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Tooltip(
        message: 'Safety number verified',
        child: Icon(Icons.verified, size: 14, color: EchoTheme.online),
      ),
    );
  }
}

/// Returns a short, human-readable label for a disappearing-messages TTL.
/// Matches the presets in `_kTtlOptions` so the chip and the dialog stay
/// visually consistent.
String _humanizeTtl(int seconds) {
  return switch (seconds) {
    30 => '30s',
    300 => '5m',
    3600 => '1h',
    86400 => '1d',
    604800 => '1w',
    _ => '${seconds}s',
  };
}

/// Small chip rendered next to a conversation's name in the chat header
/// when disappearing messages are enabled. Tapping opens the same dialog
/// that the overflow menu's "Disappearing messages" entry shows.
class _TimerChip extends StatelessWidget {
  final int seconds;
  final VoidCallback onTap;

  const _TimerChip({required this.seconds, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = _humanizeTtl(seconds);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: 'Disappearing messages',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: context.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 12,
                        color: context.accent,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: context.accent,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
