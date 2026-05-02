import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/crypto_provider.dart';
import '../../theme/echo_theme.dart';

/// Round send / mic / confirm-edit button on the right side of the input row.
class SendButton extends ConsumerWidget {
  final bool isTextEmpty;
  final bool allPendingAttachmentsReady;
  final bool isEditing;
  final bool isDm;
  final VoidCallback onStartRecording;
  final VoidCallback Function() resolveSendAction;

  const SendButton({
    super.key,
    required this.isTextEmpty,
    required this.allPendingAttachmentsReady,
    required this.isEditing,
    required this.isDm,
    required this.onStartRecording,
    required this.resolveSendAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasContent = !isTextEmpty || allPendingAttachmentsReady;

    // For DMs, gate on crypto readiness so users can't send before encryption
    // is initialized (which would fail with a confusing error).
    final cryptoState = ref.watch(cryptoProvider);
    final cryptoReady =
        cryptoState.isInitialized && !cryptoState.keysUploadFailed;
    final canSend = hasContent && (cryptoReady || !isDm);

    // When there's no content and not editing, show a bordered mic button
    // (mirrors the design's RoundIcon). It transitions to the filled accent
    // send button below as soon as content is present.
    final showMic = !hasContent && !isEditing && !kIsWeb;
    if (showMic) {
      return Semantics(
        label: 'Record voice message',
        button: true,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onStartRecording,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.surface,
                shape: BoxShape.circle,
                border: Border.all(color: context.border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.mic_outlined,
                size: 20,
                color: context.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    final Color fillColor;
    if (!canSend) {
      fillColor = context.surface;
    } else if (isEditing) {
      fillColor = EchoTheme.online;
    } else {
      fillColor = context.accent;
    }
    final iconColor = canSend ? Colors.white : context.textMuted;
    final showBorder = !canSend;

    final cryptoBlocked = isDm && !cryptoReady;

    Widget button = Semantics(
      label: isEditing ? 'Confirm edit' : 'Send message',
      button: true,
      enabled: canSend,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: canSend ? resolveSendAction() : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: fillColor,
              shape: BoxShape.circle,
              border: showBorder
                  ? Border.all(color: context.border, width: 1)
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(
              isEditing ? Icons.check_rounded : Icons.arrow_upward_rounded,
              size: 20,
              color: iconColor,
            ),
          ),
        ),
      ),
    );

    if (cryptoBlocked) {
      button = Tooltip(message: 'Encryption unavailable', child: button);
    }

    return button;
  }
}
