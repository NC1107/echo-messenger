/// Single entry point for every "Are you sure?" dialog in the app.
///
/// Before this helper, the same `showDialog<bool>` + `AlertDialog`
/// with surface background, 12-px rounded corners, border, title text,
/// content text, and a Cancel + Confirm button pair was hand-rolled in
/// 23 places. Drift had already started:
///   • Title size landed at 16 px in some places and 18 px in others.
///   • Some destructive confirms used `EchoTheme.danger` for the
///     button background; others used the default accent and just
///     changed the label to "Delete".
///   • A couple of sites had the dialog mounted-check, most didn't.
///
/// `showEchoConfirmDialog` bakes in the dialog chrome and forces a
/// single `destructive` flag for the red-confirm variant. Changing the
/// dialog's corner radius, border, or destructive treatment is a
/// one-line edit here instead of a 23-file sweep.
library;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Show a confirm-or-cancel dialog. Returns `true` when the user taps
/// the confirm button, `false` on cancel or barrier dismiss.
///
/// [destructive] swaps the confirm button to `EchoTheme.danger` and is
/// the visual cue that the action is irreversible (delete, remove,
/// leave, etc.). Default false.
///
/// [content] is the prompt body. Accepts either a [String] (rendered
/// with the standard styling) or a [Widget] for richer bodies (e.g. a
/// list of consequences). When you only need text, pass a String.
Future<bool> showEchoConfirmDialog(
  BuildContext context, {
  required String title,
  required Object content,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) {
      final body = content is Widget
          ? content
          : Text(
              content.toString(),
              style: TextStyle(color: dialogCtx.textSecondary, fontSize: 14),
            );
      return AlertDialog(
        backgroundColor: dialogCtx.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: dialogCtx.border),
        ),
        title: Text(
          title,
          style: TextStyle(
            // Destructive confirms colour the title red as an extra
            // signal beyond the red confirm button — matches the
            // pattern conversation_panel and chat_header_bar already
            // used by hand.
            color: destructive ? EchoTheme.danger : dialogCtx.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: body,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: EchoTheme.danger)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
