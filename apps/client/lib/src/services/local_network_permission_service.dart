import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shows a one-time explainer dialog on iOS/macOS before the OS surfaces
/// its "find and connect to devices on your local network" prompt.
///
/// Without context, beta testers tap "Don't Allow" and silently break the
/// app's ability to reach a self-hosted server on the same network. This
/// service primes the user so they understand why the next system popup
/// is appearing and what tapping Allow does.
class LocalNetworkPermissionService {
  LocalNetworkPermissionService._();

  /// SharedPreferences key tracking whether the explainer has been shown.
  @visibleForTesting
  static const String prefsKey = 'local_network_explainer_shown';

  /// Show the explainer once on iOS or macOS. No-op on other platforms or
  /// on subsequent launches. Safe to call multiple times.
  ///
  /// Callers should `await` this BEFORE the first non-loopback HTTP/WS
  /// connection so the dialog precedes the OS permission popup.
  static Future<void> showIfNeeded(BuildContext context) async {
    // Restrict to platforms where iOS-style local network permission is
    // gated by the OS. Other platforms grant access implicitly.
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefsKey) == true) {
      return;
    }

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Local network access'),
          content: const Text(
            'Echo connects to its server over your local network. '
            'The next system popup asks for permission — please tap Allow.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );

    await prefs.setBool(prefsKey, true);
  }
}
