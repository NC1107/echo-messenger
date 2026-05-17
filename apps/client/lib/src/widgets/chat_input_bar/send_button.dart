import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/crypto_provider.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

// ---------------------------------------------------------------------------
// Internal value object — groups the six per-mode properties so the resolver
// can return them as a single unit instead of assigning them one-by-one.
// ---------------------------------------------------------------------------
class _ButtonState {
  const _ButtonState({
    required this.iconData,
    required this.iconColor,
    required this.fillColor,
    required this.showBorder,
    required this.onTap,
    required this.semanticLabel,
    required this.iconKey,
  });

  final IconData iconData;
  final Color iconColor;
  final Color fillColor;
  final bool showBorder;
  final VoidCallback? onTap;
  final String semanticLabel;
  final ValueKey<String> iconKey;
}

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

  // -------------------------------------------------------------------------
  // Resolve the six mode-dependent properties for the current widget state.
  // -------------------------------------------------------------------------
  _ButtonState _resolveButtonState(
    BuildContext context, {
    required bool showMic,
    required bool canSend,
  }) {
    if (showMic) {
      return _ButtonState(
        iconData: Icons.mic_outlined,
        iconColor: context.textSecondary,
        fillColor: context.surface,
        showBorder: true,
        onTap: onStartRecording,
        semanticLabel: 'Record voice message',
        iconKey: const ValueKey('mic'),
      );
    }
    if (isEditing) {
      return _ButtonState(
        iconData: Icons.check_rounded,
        iconColor: canSend ? Colors.white : context.textMuted,
        fillColor: canSend ? EchoTheme.online : context.surface,
        showBorder: !canSend,
        onTap: canSend ? resolveSendAction() : null,
        semanticLabel: 'Confirm edit',
        iconKey: const ValueKey('check'),
      );
    }
    return _ButtonState(
      iconData: Icons.arrow_upward_rounded,
      iconColor: canSend ? Colors.white : context.textMuted,
      fillColor: canSend ? context.accent : context.surface,
      showBorder: !canSend,
      onTap: canSend ? resolveSendAction() : null,
      semanticLabel: 'Send message',
      iconKey: const ValueKey('send'),
    );
  }

  // -------------------------------------------------------------------------
  // Build the animated Material circle button from a resolved _ButtonState.
  // -------------------------------------------------------------------------
  Widget _buildAnimatedButton(BuildContext context, _ButtonState s) {
    return Semantics(
      label: s.semanticLabel,
      button: true,
      enabled: s.onTap != null,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: s.onTap,
          child: AnimatedContainer(
            duration: MotionDurations.standard,
            curve: MotionCurves.emphasis,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: s.fillColor,
              shape: BoxShape.circle,
              border: s.showBorder
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
              child: Icon(
                s.iconData,
                key: s.iconKey,
                size: 20,
                color: s.iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

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

    final state = _resolveButtonState(
      context,
      showMic: showMic,
      canSend: canSend,
    );
    Widget button = _buildAnimatedButton(context, state);

    final cryptoBlocked = isDm && !cryptoReady;
    if (cryptoBlocked) {
      button = Tooltip(message: 'Encryption unavailable', child: button);
    }

    return button;
  }
}
