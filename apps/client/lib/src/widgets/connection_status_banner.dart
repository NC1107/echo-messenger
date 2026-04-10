import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

/// Displays a slim banner at the top of the chat area to indicate WebSocket
/// connection status. Only visible when disconnected or briefly when reconnecting.
/// Slides in with a 200ms animation and auto-dismisses 1.5s after reconnecting.
class ConnectionStatusBanner extends ConsumerStatefulWidget {
  const ConnectionStatusBanner({super.key});

  @override
  ConsumerState<ConnectionStatusBanner> createState() =>
      _ConnectionStatusBannerState();
}

class _ConnectionStatusBannerState
    extends ConsumerState<ConnectionStatusBanner> {
  // Shows the green "Connected" flash for 1.5s after reconnecting.
  bool _showConnectedFlash = false;
  Timer? _flashTimer;
  bool _wasDisconnected = false;

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wsState = ref.watch(websocketProvider);

    // Detect transition from disconnected -> connected.
    if (!wsState.isConnected) {
      _wasDisconnected = true;
    } else if (_wasDisconnected &&
        wsState.isConnected &&
        !_showConnectedFlash) {
      _wasDisconnected = false;
      _showConnectedFlash = true;
      _flashTimer?.cancel();
      _flashTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _showConnectedFlash = false);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    final bool visible =
        !wsState.isConnected || _showConnectedFlash || wsState.wasReplaced;
    if (!visible) return const SizedBox.shrink();

    final bool maxAttemptsReached =
        wsState.reconnectAttempts >= 10 && !wsState.isConnected;

    Color bannerColor;
    String label;
    bool showSpinner = false;

    if (wsState.wasReplaced) {
      bannerColor = EchoTheme.danger;
      label = 'Signed in on another device';
    } else if (wsState.isConnected && _showConnectedFlash) {
      bannerColor = EchoTheme.online;
      label = 'Connected';
    } else if (maxAttemptsReached) {
      bannerColor = EchoTheme.danger;
      label = 'Connection lost';
    } else {
      bannerColor = const Color(0xFFB45309); // amber-700
      label = wsState.reconnectAttempts > 0
          ? 'Reconnecting... (${wsState.reconnectAttempts})'
          : 'Reconnecting...';
      showSpinner = true;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Container(
        width: double.infinity,
        color: bannerColor.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showSpinner)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: bannerColor,
                  ),
                ),
              if (showSpinner) const SizedBox(width: 6),
              if (!showSpinner && wsState.isConnected)
                Icon(Icons.check_circle_outline, size: 12, color: bannerColor),
              if (!showSpinner && !wsState.isConnected)
                Icon(Icons.wifi_off_outlined, size: 12, color: bannerColor),
              if (!showSpinner) const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: bannerColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (maxAttemptsReached || wsState.wasReplaced) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => ref.read(websocketProvider.notifier).connect(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: bannerColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: bannerColor, width: 1),
                    ),
                    child: Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 11,
                        color: bannerColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
