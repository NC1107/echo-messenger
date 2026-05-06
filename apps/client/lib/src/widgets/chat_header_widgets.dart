/// Small widget components used by [ChatHeaderBar] (extracted from
/// `chat_header_bar.dart` to keep the parent file focused on layout).
///
/// - [IdentityChangedBadge] — TOFU warning next to a peer's name.
/// - [VerifiedBadge] — green check after manual safety-number verification.
/// - [TimerChip] — disappearing-messages countdown chip.
/// - [PinnedMessagesDialog] — modal listing a conversation's pinned messages.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../services/message_cache.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';

const _kAuthorizationHeader = 'Authorization';
const _kDisappearingMessagesLabel = 'Disappearing messages';

/// Small red warning triangle shown next to a DM peer's name when the
/// crypto layer has flagged the peer's identity key as changed (TOFU
/// violation). Tapping opens the safety-number screen so the user can
/// compare the new key out-of-band before trusting it.
class IdentityChangedBadge extends ConsumerStatefulWidget {
  final String peerUserId;

  const IdentityChangedBadge({super.key, required this.peerUserId});

  @override
  ConsumerState<IdentityChangedBadge> createState() =>
      _IdentityChangedBadgeState();
}

class _IdentityChangedBadgeState extends ConsumerState<IdentityChangedBadge> {
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant IdentityChangedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerUserId != widget.peerUserId) {
      setState(() => _changed = false);
      _load();
    }
  }

  Future<void> _load() async {
    final crypto = ref.read(cryptoProvider);
    if (!crypto.isInitialized) return;
    final flag = await ref
        .read(cryptoProvider.notifier)
        .hasPeerIdentityKeyChanged(widget.peerUserId);
    if (!mounted) return;
    if (flag != _changed) setState(() => _changed = flag);
  }

  @override
  Widget build(BuildContext context) {
    if (!_changed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Semantics(
        label: 'identity changed warning',
        child: const Tooltip(
          message: "Identity changed -- verify safety number",
          child: Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: EchoTheme.warning,
          ),
        ),
      ),
    );
  }
}

/// Tiny green check shown next to a DM peer's name when the user has
/// previously verified their safety number. Reads `echo_safety_verified_<id>`
/// from SharedPreferences. Clears itself if the pref changes between rebuilds
/// (see IdentityKeyChangedBanner which removes the pref on TOFU).
class VerifiedBadge extends StatefulWidget {
  final String peerUserId;

  const VerifiedBadge({super.key, required this.peerUserId});

  @override
  State<VerifiedBadge> createState() => _VerifiedBadgeState();
}

class _VerifiedBadgeState extends State<VerifiedBadge> {
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _loadVerified();
  }

  @override
  void didUpdateWidget(covariant VerifiedBadge oldWidget) {
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
class TimerChip extends StatelessWidget {
  final int seconds;
  final VoidCallback onTap;

  const TimerChip({super.key, required this.seconds, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = _humanizeTtl(seconds);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: _kDisappearingMessagesLabel,
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
                        style: GoogleFonts.inter(
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
class PinnedMessagesDialog extends ConsumerStatefulWidget {
  final String conversationId;
  final String serverUrl;
  final String myUserId;

  const PinnedMessagesDialog({
    super.key,
    required this.conversationId,
    required this.serverUrl,
    required this.myUserId,
  });

  @override
  ConsumerState<PinnedMessagesDialog> createState() =>
      _PinnedMessagesDialogState();
}

class _PinnedMessagesDialogState extends ConsumerState<PinnedMessagesDialog> {
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
                _kAuthorizationHeader: 'Bearer $token',
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
        // The /pinned endpoint returns the raw stored content, which is
        // ciphertext for encrypted DMs.  Re-hydrate from the per-conversation
        // message cache (which stores the decrypted view) so users see the
        // plaintext they expect.  Falls back to the server payload if the
        // message isn't in the cache (e.g. pinned before this device joined
        // the conversation) -- in that case the user still sees something is
        // pinned, just as ciphertext, which matches the prior behavior (#724).
        final messages = <ChatMessage>[];
        for (final e in list) {
          final raw = ChatMessage.fromServerJson(
            e as Map<String, dynamic>,
            widget.myUserId,
          );
          final cached = await MessageCache.getCachedMessage(
            widget.conversationId,
            raw.id,
            widget.myUserId,
          );
          messages.add(cached ?? raw);
        }
        if (!mounted) return;
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
              headers: {_kAuthorizationHeader: 'Bearer $token'},
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
            style: GoogleFonts.inter(
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
          style: GoogleFonts.inter(color: context.textMuted, fontSize: 14),
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
              style: GoogleFonts.inter(color: context.textMuted, fontSize: 14),
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
                      style: GoogleFonts.inter(
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
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMessageTimestamp(msg.timestamp),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: context.textMuted,
                      ),
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
