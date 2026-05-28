import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time disclosure that voice-lounge canvas content is not end-to-end
/// encrypted, even in encrypted conversations.
///
/// See `docs/voice-lounge/04-encrypted-canvas.md` for the contract that
/// motivates this notice and the pickup plan tracked at #1268.
class EncryptedCanvasNotice {
  /// SharedPreferences key. `_v1` so a future content rewrite can re-prompt
  /// by bumping to `_v2` without losing the historical signal.
  static const String prefsKey = 'seen_encrypted_canvas_notice_v1';

  /// Shows the popup once per device. No-op when:
  ///   * `isEncrypted` is false, or
  ///   * the user has already dismissed the popup on this install.
  ///
  /// Safe to call from `addPostFrameCallback` in a lounge screen's
  /// `initState`. Awaits internally; callers can ignore the future.
  static Future<void> maybeShow(
    BuildContext context, {
    required bool isEncrypted,
  }) async {
    if (!isEncrypted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefsKey) ?? false) return;
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text("Canvas isn't encrypted yet"),
        content: const Text(
          'Drawings, screen-share positions, and avatar moves in voice '
          'lounges are currently visible to the server, even in encrypted '
          'conversations. End-to-end encryption for the canvas is on the '
          'way (tracked at #1268). This message will not appear again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );

    await prefs.setBool(prefsKey, true);
  }
}
