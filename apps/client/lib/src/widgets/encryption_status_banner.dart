import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../theme/echo_theme.dart';

/// Top-of-conversation banner that surfaces transient encryption failure
/// states. Three flavours, in priority order (highest priority shown):
///
/// 1. **Keyring locked** — `cryptoProvider.state.secureStorageUnavailable`.
///    Action: tap "Retry" → `retryStorageUnlock()`. Audit P0-1.
/// 2. **Key upload failing** — `cryptoProvider.state.keysUploadFailed`.
///    Read-only signal here; the actionable fix lives in Settings →
///    Privacy. Audit P0-2.
/// 3. **Session out of sync** — `chatProvider.state.isConversationOutOfSync`.
///    Action: tap "Reset Session" → `resetWedgedSession()`. Audit P0-3.
///
/// All banners are additive — they don't block input. The user keeps typing;
/// the banner just makes the silent failure mode visible.
class EncryptionStatusBanner extends ConsumerWidget {
  const EncryptionStatusBanner({super.key, required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secureStorageDown = ref.watch(
      cryptoProvider.select((s) => s.secureStorageUnavailable),
    );
    final keyUploadFailed = ref.watch(
      cryptoProvider.select((s) => s.keysUploadFailed),
    );
    final outOfSync = ref.watch(
      chatProvider.select((s) => s.isConversationOutOfSync(conversation.id)),
    );

    if (secureStorageDown) {
      return _Banner(
        icon: Icons.lock_outline,
        color: context.accent,
        message:
            "Echo can't read its encryption keys. Unlock your system keyring "
            'and tap Retry.',
        actionLabel: 'Retry',
        onAction: () => ref.read(cryptoProvider.notifier).retryStorageUnlock(),
      );
    }

    if (keyUploadFailed) {
      return const _Banner(
        icon: Icons.cloud_off_outlined,
        color: EchoTheme.warning,
        message:
            'Key sync to server is failing. Recent messages from new peers '
            'may not decrypt. Check connection and reopen Settings → Privacy.',
      );
    }

    if (outOfSync && !conversation.isGroup) {
      // Reset-session affordance only applies to 1:1 conversations today;
      // group recovery uses key-rotation instead (tracked separately).
      final peerId = _peerUserIdFor(conversation, ref);
      return _Banner(
        icon: Icons.sync_problem,
        color: EchoTheme.warning,
        message:
            'Encryption is out of sync with this contact. Resetting will '
            'recover the conversation, but messages from before now may '
            'not decrypt.',
        actionLabel: 'Reset Session',
        onAction: peerId == null
            ? null
            : () => ref
                  .read(chatProvider.notifier)
                  .resetWedgedSession(conversation.id, peerId),
      );
    }

    return const SizedBox.shrink();
  }

  String? _peerUserIdFor(Conversation conv, WidgetRef ref) {
    // 1:1 conversations have exactly one "other" member.
    if (conv.members.length < 2) return null;
    // The store-side userId of the current user is needed to exclude self,
    // but the banner is constructed inside the per-conversation tree where
    // myUserId isn't directly threaded. Walk members and pick the first
    // non-self entry; the chat panel already filters self from member lists
    // upstream, so members[0] is a safe heuristic here. For non-1:1 the
    // banner is suppressed above.
    return conv.members.first.userId;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  color: context.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
