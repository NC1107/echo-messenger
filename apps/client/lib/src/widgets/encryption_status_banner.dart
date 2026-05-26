import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../theme/echo_theme.dart';
import 'echo_banner.dart';

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
      return EchoBanner(
        icon: Icons.lock_outline,
        severity: EchoBannerSeverity.info,
        message:
            "Echo can't read its encryption keys. Unlock your system keyring "
            'and tap Retry.',
        action: _action(
          context,
          'Retry',
          () => ref.read(cryptoProvider.notifier).retryStorageUnlock(),
          EchoBannerSeverity.info,
        ),
      );
    }

    if (keyUploadFailed) {
      return const EchoBanner(
        icon: Icons.cloud_off_outlined,
        severity: EchoBannerSeverity.warning,
        message:
            'Key sync to server is failing. Recent messages from new peers '
            'may not decrypt. Check connection and reopen Settings → Privacy.',
      );
    }

    if (sigFailed && conversation.isGroup) {
      // GRP2 signature mismatch could be device-rotation race OR forgery — no auto-recover; user dismisses explicitly.
      return EchoBanner(
        icon: Icons.gpp_bad_outlined,
        severity: EchoBannerSeverity.danger,
        message:
            "Couldn't verify the sender of a message in this group. "
            'Contact an admin before treating recent messages as authentic.',
        action: _action(
          context,
          'Dismiss',
          () => ref
              .read(chatProvider.notifier)
              .dismissSignatureFailure(conversation.id),
          EchoBannerSeverity.danger,
        ),
      );
    }

    if ((needsRotation || outOfSync) && conversation.isGroup) {
      // needsRotation = server 410 (no envelope at current version); outOfSync = decrypt-failure threshold tripped.
      final message = needsRotation
          ? "This group's encryption key was rotated without you. Ask any "
                'active member to refresh and send a message — the new '
                'envelope will be delivered to you.'
          : "Can't decrypt this group's recent messages. The encryption key "
                'may have rotated — refresh to fetch the latest.';
      return EchoBanner(
        icon: Icons.refresh,
        severity: EchoBannerSeverity.warning,
        message: message,
        action: _action(
          context,
          'Refresh key',
          () =>
              ref.read(chatProvider.notifier).refreshGroupKey(conversation.id),
          EchoBannerSeverity.warning,
        ),
      );
    }

    if (outOfSync && !conversation.isGroup) {
      final peerId = _peerUserIdFor(conversation, ref);
      return EchoBanner(
        icon: Icons.sync_problem,
        severity: EchoBannerSeverity.warning,
        message:
            'Encryption is out of sync with this contact. Resetting will '
            'recover the conversation, but messages from before now may '
            'not decrypt.',
        action: _action(
          context,
          'Reset Session',
          peerId == null
              ? null
              : () => ref
                    .read(chatProvider.notifier)
                    .resetWedgedSession(conversation.id, peerId),
          EchoBannerSeverity.warning,
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _action(
    BuildContext context,
    String label,
    VoidCallback? onPressed,
    EchoBannerSeverity severity,
  ) {
    final color = switch (severity) {
      EchoBannerSeverity.info => context.accent,
      EchoBannerSeverity.warning => EchoTheme.warning,
      EchoBannerSeverity.danger => EchoTheme.danger,
    };
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(label),
    );
  }

  String? _peerUserIdFor(Conversation conv, WidgetRef ref) {
    if (conv.members.length < 2) return null;
    // Chat panel already filters self from member lists upstream, so members.first is the peer.
    return conv.members.first.userId;
  }
}
