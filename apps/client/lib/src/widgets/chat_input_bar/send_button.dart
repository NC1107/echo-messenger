import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/crypto_provider.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

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

    // Three visual modes share one container so the transitions between
    // them animate via AnimatedContainer + AnimatedSwitcher rather than
    // snapping (mic ↔ send-arrow on first keystroke; send-arrow ↔ check
    // on edit-mode entry; disabled ↔ enabled fill color).
    final bool showMic = !hasContent && !isEditing && !kIsWeb;

    final IconData iconData;
    final Color iconColor;
    final Color fillColor;
    final bool showBorder;
    final VoidCallback? onTap;
    final String semanticLabel;
    final ValueKey<String> iconKey;

    if (showMic) {
      iconData = Icons.mic_outlined;
      iconColor = context.textSecondary;
      fillColor = context.surface;
      showBorder = true;
      onTap = onStartRecording;
      semanticLabel = 'Record voice message';
      iconKey = const ValueKey('mic');
    } else if (isEditing) {
      iconData = Icons.check_rounded;
      iconColor = canSend ? Colors.white : context.textMuted;
      fillColor = canSend ? EchoTheme.online : context.surface;
      showBorder = !canSend;
      onTap = canSend ? resolveSendAction() : null;
      semanticLabel = 'Confirm edit';
      iconKey = const ValueKey('check');
    } else {
      iconData = Icons.arrow_upward_rounded;
      iconColor = canSend ? Colors.white : context.textMuted;
      fillColor = canSend ? context.accent : context.surface;
      showBorder = !canSend;
      onTap = canSend ? resolveSendAction() : null;
      semanticLabel = 'Send message';
      iconKey = const ValueKey('send');
    }

    final cryptoBlocked = isDm && !cryptoReady;

    Widget button = Semantics(
      label: semanticLabel,
      button: true,
      enabled: showMic ? true : canSend,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: AnimatedContainer(
            duration: MotionDurations.standard,
            curve: MotionCurves.emphasis,
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
            child: AnimatedSwitcher(
              duration: MotionDurations.quick,
              switchInCurve: MotionCurves.emphasis,
              switchOutCurve: MotionCurves.exit,
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(iconData, key: iconKey, size: 20, color: iconColor),
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
