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

  /// Track connection transition and trigger the green "Connected" flash.
  void _trackConnectionTransition(WebSocketState wsState) {
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
  }

  /// Resolve the banner color, label, and spinner visibility from ws state.
  ({Color color, String label, bool showSpinner}) _resolveBannerStatus(
    WebSocketState wsState,
  ) {
    final maxAttemptsReached =
        wsState.reconnectAttempts >= 10 && !wsState.isConnected;

    if (wsState.wasReplaced) {
      return (
        color: EchoTheme.danger,
        label: 'Signed in on another device',
        showSpinner: false,
      );
    }
    if (wsState.isConnected && _showConnectedFlash) {
      return (color: EchoTheme.online, label: 'Connected', showSpinner: false);
    }
    if (maxAttemptsReached) {
      return (
        color: EchoTheme.danger,
        label: 'Connection lost \u2014 messages may be pending',
        showSpinner: false,
      );
    }
    return (
      color: EchoTheme.warning,
      label: wsState.reconnectAttempts > 0
          ? 'Reconnecting... (${wsState.reconnectAttempts})'
          : 'Reconnecting...',
      showSpinner: true,
    );
  }

  /// Build the leading icon/spinner for the banner.
  Widget _buildLeadingIcon({
    required bool showSpinner,
    required bool isConnected,
    required Color bannerColor,
  }) {
    if (showSpinner) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: bannerColor,
            ),
          ),
          const SizedBox(width: 6),
        ],
      );
    }
    final icon = isConnected
        ? Icons.check_circle_outline
        : Icons.wifi_off_outlined;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: bannerColor),
        const SizedBox(width: 6),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wsState = ref.watch(websocketProvider);
    _trackConnectionTransition(wsState);

    final bool visible =
        !wsState.isConnected || _showConnectedFlash || wsState.wasReplaced;
    if (!visible) return const SizedBox.shrink();

    final status = _resolveBannerStatus(wsState);
    final showRetry =
        (wsState.reconnectAttempts >= 10 && !wsState.isConnected) ||
        wsState.wasReplaced;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Container(
        width: double.infinity,
        color: status.color.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLeadingIcon(
                showSpinner: status.showSpinner,
                isConnected: wsState.isConnected,
                bannerColor: status.color,
              ),
              Text(
                status.label,
                style: TextStyle(
                  fontSize: 12,
                  color: status.color,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (showRetry) ...[
                const SizedBox(width: 10),
                Semantics(
                  label: 'retry connection',
                  button: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          ref.read(websocketProvider.notifier).connect(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: status.color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: status.color, width: 1),
                        ),
                        child: Text(
                          'Retry',
                          style: TextStyle(
                            fontSize: 11,
                            color: status.color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
