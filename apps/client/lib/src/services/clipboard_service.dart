/// Copy-text-and-toast helper.
///
/// `Clipboard.setData(ClipboardData(text: …))` + `ToastService.show(…)`
/// was repeated in 10+ places — account section, profile sheet, safety
/// number, message actions, group info, settings sections. Each call
/// site picked its own toast wording and type. This helper standardises
/// the success message and the toast type while still allowing per-call
/// overrides for context-specific copy ("Username copied" vs "Invite
/// link copied" vs "Message ID copied").
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'toast_service.dart';

/// Copy [text] to the system clipboard and show a success toast.
///
/// [successMessage] defaults to `'Copied'`; pass a more specific label
/// when the context is ambiguous (e.g. `'Invite link copied'`,
/// `'Username copied'`). Pass `null` to skip the toast entirely.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  String? successMessage = 'Copied',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted || successMessage == null) return;
  ToastService.show(context, successMessage, type: ToastType.success);
}
