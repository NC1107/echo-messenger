/// Single entry point for every "type a value" prompt dialog in the app.
///
/// Companion to [showEchoConfirmDialog]: confirm asks yes/no, this asks
/// for a short string (server URL, group name, profile shortcut, etc.).
/// Before this helper the same `showDialog<String>` with an `AlertDialog`
/// wrapping a [TextField] + Cancel / Confirm buttons was hand-rolled in
/// ~10 places — title size, autofocus behaviour, validator wiring, and
/// the Enter-to-submit detail all drifted.
///
/// Returns the entered string when the user confirms (or presses Enter
/// with a non-empty value), or `null` on cancel / barrier dismiss / empty
/// value. Callers that need richer validation should branch on the
/// return value themselves; this helper deliberately doesn't bake in an
/// inline error state to keep the contract simple.
library;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Show an Echo-styled single-line input prompt. Returns the trimmed
/// entered value when the user confirms, or `null` on dismiss/empty.
///
/// [destructive] swaps the confirm button to the danger colour for
/// prompts that gate a destructive action (rare, but kept for parity
/// with [showEchoConfirmDialog]).
Future<String?> showEchoInputDialog(
  BuildContext context, {
  required String title,
  String? hintText,
  String? helperText,
  String? initialValue,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  TextInputType keyboardType = TextInputType.text,
  bool destructive = false,
  bool obscureText = false,
  int? maxLength,
}) async {
  final controller = TextEditingController(text: initialValue ?? '');
  try {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        void submit() {
          final value = controller.text.trim();
          if (value.isEmpty) {
            Navigator.pop(dialogCtx);
            return;
          }
          Navigator.pop(dialogCtx, value);
        }

        return AlertDialog(
          backgroundColor: dialogCtx.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            side: BorderSide(color: dialogCtx.border),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: destructive ? EchoTheme.danger : dialogCtx.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: keyboardType,
            obscureText: obscureText,
            maxLength: maxLength,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
              hintText: hintText,
              helperText: helperText,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(cancelLabel),
            ),
            FilledButton(
              onPressed: submit,
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: EchoTheme.danger)
                  : null,
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result;
  } finally {
    controller.dispose();
  }
}
