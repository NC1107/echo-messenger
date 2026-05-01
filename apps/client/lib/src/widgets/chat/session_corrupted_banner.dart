import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../providers/chat_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

/// Amber banner shown in the chat panel header when the Signal session for
/// [peerUserId] was quarantined (repeated decrypt failures on startup).
///
/// Tapping "Reset" calls [CryptoNotifier.forceResetSession] (clears the
/// quarantined key material and drops the bad session) then notifies the peer
/// via the WebSocket key-reset event so they also flush their stale session.
/// The banner hides itself after a successful reset.
class SessionCorruptedBanner extends ConsumerStatefulWidget {
  final String conversationId;
  final String peerUserId;
  final String peerName;

  const SessionCorruptedBanner({
    super.key,
    required this.conversationId,
    required this.peerUserId,
    required this.peerName,
  });

  @override
  ConsumerState<SessionCorruptedBanner> createState() =>
      _SessionCorruptedBannerState();
}

class _SessionCorruptedBannerState
    extends ConsumerState<SessionCorruptedBanner> {
  /// Set to true optimistically after the user taps Reset, so the banner
  /// hides before the next provider rebuild.
  bool _dismissed = false;

  bool get _isCorrupted {
    if (_dismissed) return false;
    final cryptoState = ref.watch(cryptoProvider);
    if (!cryptoState.isInitialized) return false;
    return ref
        .read(cryptoProvider.notifier)
        .hasCorruptedSession(widget.peerUserId);
  }

  Future<void> _reset() async {
    setState(() => _dismissed = true);
    try {
      await ref
          .read(cryptoProvider.notifier)
          .forceResetSession(widget.peerUserId);
      // Tell the peer to flush their stale session too.
      ref.read(websocketProvider.notifier).sendKeyReset(widget.conversationId);
      // Add a timeline event so the conversation reflects the reset.
      ref
          .read(chatProvider.notifier)
          .addSystemEvent(
            widget.conversationId,
            'Encryption session reset — next message will establish a new session',
          );
      if (mounted) {
        ToastService.show(
          context,
          'Encryption reset. Next message will establish a fresh session.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _dismissed = false);
        ToastService.show(
          context,
          'Failed to reset session: $e',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCorrupted) return const SizedBox.shrink();

    return Semantics(
      label: 'encryption session corrupted warning',
      child: Container(
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
            Expanded(
              child: Text(
                'Encryption with @${widget.peerName} needs a reset. Tap to reset.',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: EchoTheme.warning,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: 'reset encryption session',
              button: true,
              child: GestureDetector(
                onTap: _reset,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: EchoTheme.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: EchoTheme.warning.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    'Reset',
                    style: GoogleFonts.inter(
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
      ),
    );
  }
}
