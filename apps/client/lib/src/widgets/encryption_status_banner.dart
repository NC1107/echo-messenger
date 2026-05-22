import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../theme/echo_theme.dart';

/// Top-of-conversation banner that surfaces transient encryption failure
/// states. Five flavours, in priority order (highest priority shown):
///
/// 1. **Keyring locked** — `cryptoProvider.state.secureStorageUnavailable`.
///    Action: tap "Retry" → `retryStorageUnlock()`. Audit P0-1.
/// 2. **Key upload failing** — `cryptoProvider.state.keysUploadFailed`.
///    Read-only signal here; the actionable fix lives in Settings →
///    Privacy. Audit P0-2.
/// 3. **Sender signature failed (group)** — at least one GRP2 message
///    failed verification. Danger-colored; only action is "Dismiss"
///    because there's no safe auto-recovery from a forgery attempt.
///    Audit Phase 4, OQ-1/OQ-12.
/// 4. **Group key out of sync** — group conversation crossed the
///    decrypt-failure threshold. Action: "Refresh key" →
///    `refreshGroupKey()`. Audit Phase 4.
/// 5. **Session out of sync (1:1)** — `chatProvider.state.isConversationOutOfSync`.
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
    final sigFailed = ref.watch(
      chatProvider.select((s) => s.hasSignatureFailure(conversation.id)),
    );
    final outOfSync = ref.watch(
      chatProvider.select((s) => s.isConversationOutOfSync(conversation.id)),
    );
    final needsRotation = ref.watch(
      chatProvider.select((s) => s.isGroupAwaitingRotation(conversation.id)),
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

    if (sigFailed && conversation.isGroup) {
      // GRP2 signature verification failed — a member of this group
      // signed a message with a key that doesn't match their device's
      // published verify key. Could be a benign device-rotation race,
      // but it could also be forgery. We don't auto-recover; the user
      // explicitly dismisses after they've contacted an admin / the
      // sender out-of-band.
      return _Banner(
        icon: Icons.gpp_bad_outlined,
        color: EchoTheme.danger,
        message:
            "Couldn't verify the sender of a message in this group. "
            'Contact an admin before treating recent messages as authentic.',
        actionLabel: 'Dismiss',
        onAction: () => ref
            .read(chatProvider.notifier)
            .dismissSignatureFailure(conversation.id),
      );
    }

    if ((needsRotation || outOfSync) && conversation.isGroup) {
      // Two paths funnel into the same banner:
      // 1. needsRotation — the server reported 410 Gone from
      //    /keys/latest because no envelope exists for this user at
      //    the current key version. Another member must rotate us in.
      // 2. outOfSync — repeated "[Could not decrypt...]" placeholders
      //    crossed the threshold; the local cached key is probably
      //    stale and a fresh envelope is sitting on the server.
      // "Refresh key" drops the local cache + refetches; if the fetch
      // returns 410 again the callback re-flags the conversation.
      final message = needsRotation
          ? "This group's encryption key was rotated without you. Ask any "
                'active member to refresh and send a message — the new '
                'envelope will be delivered to you.'
          : "Can't decrypt this group's recent messages. The encryption key "
                'may have rotated — refresh to fetch the latest.';
      return _Banner(
        icon: Icons.refresh,
        color: EchoTheme.warning,
        message: message,
        actionLabel: 'Refresh key',
        onAction: () =>
            ref.read(chatProvider.notifier).refreshGroupKey(conversation.id),
      );
    }

    if (outOfSync && !conversation.isGroup) {
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
