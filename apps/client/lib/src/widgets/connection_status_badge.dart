import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../version.dart';

/// Threshold past which we stop calling the state "reconnecting" and start
/// calling it "offline". Matches the legacy chat-header dot's display logic;
/// the websocket notifier itself keeps trying for up to 1000 attempts.
const int _kReconnectingCutoff = 10;

const double _kPopoverMaxWidth = 280;
const double _kViewportPadding = 8;
const Duration _kHoverGrace = Duration(milliseconds: 150);
const Duration _kPulse = Duration(seconds: 1);

/// Visible name for the connection state. Exposed for popover content and
/// the diagnostics block.
enum _ConnectionStateKind { connected, reconnecting, offline, replaced }

_ConnectionStateKind _kindFor({
  required bool isConnected,
  required int reconnectAttempts,
  required bool wasReplaced,
}) {
  if (wasReplaced) return _ConnectionStateKind.replaced;
  if (isConnected) return _ConnectionStateKind.connected;
  if (reconnectAttempts >= _kReconnectingCutoff) {
    return _ConnectionStateKind.offline;
  }
  return _ConnectionStateKind.reconnecting;
}

Color _dotColorFor(_ConnectionStateKind kind) {
  switch (kind) {
    case _ConnectionStateKind.connected:
      return EchoTheme.online;
    case _ConnectionStateKind.reconnecting:
      return EchoTheme.warning;
    case _ConnectionStateKind.offline:
    case _ConnectionStateKind.replaced:
      return EchoTheme.danger;
  }
}

String _titleFor(_ConnectionStateKind kind) {
  switch (kind) {
    case _ConnectionStateKind.connected:
      return 'Connected';
    case _ConnectionStateKind.reconnecting:
      return 'Reconnecting…';
    case _ConnectionStateKind.offline:
      return 'Offline';
    case _ConnectionStateKind.replaced:
      return 'Signed in elsewhere';
  }
}

String _subtitleFor(_ConnectionStateKind kind, int attempts) {
  switch (kind) {
    case _ConnectionStateKind.connected:
      return 'Messages are delivered in real time.';
    case _ConnectionStateKind.reconnecting:
      return 'Attempt $attempts of $_kReconnectingCutoff. '
          'Backing off between tries.';
    case _ConnectionStateKind.offline:
      return "Couldn't reach the server after "
          '$_kReconnectingCutoff tries.';
    case _ConnectionStateKind.replaced:
      return 'Your account is active on another device. '
          'Sign in here to resume.';
  }
}

String _kindLabel(_ConnectionStateKind kind) => switch (kind) {
  _ConnectionStateKind.connected => 'connected',
  _ConnectionStateKind.reconnecting => 'reconnecting',
  _ConnectionStateKind.offline => 'offline',
  _ConnectionStateKind.replaced => 'replaced',
};

/// A small status dot anchored to the bottom-right of [child] that opens a
/// detail popover on hover (desktop) or tap (mobile). Mirrors the avatar
/// presence-dot pattern used in `conversation_item.dart` and `members_panel.dart`
/// (2 px sidebar-coloured border).
class ConnectionStatusBadge extends ConsumerStatefulWidget {
  final Widget child;
  final double dotSize;
  final EdgeInsets dotInset;

  const ConnectionStatusBadge({
    super.key,
    required this.child,
    this.dotSize = 8,
    this.dotInset = EdgeInsets.zero,
  });

  @override
  ConsumerState<ConnectionStatusBadge> createState() =>
      _ConnectionStatusBadgeState();
}

class _ConnectionStatusBadgeState extends ConsumerState<ConnectionStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  final OverlayPortalController _overlayController = OverlayPortalController();
  final GlobalKey _triggerKey = GlobalKey();
  Timer? _hideTimer;
  _ConnectionStateKind? _lastKind;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: _kPulse);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _pulseController.dispose();
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    super.dispose();
  }

  void _syncPulse(_ConnectionStateKind kind) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (kind == _ConnectionStateKind.reconnecting && !reduceMotion) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat();
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 0.0;
    }
  }

  void _showPopover() {
    _hideTimer?.cancel();
    if (!_overlayController.isShowing) {
      _overlayController.show();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_kHoverGrace, () {
      if (mounted && _overlayController.isShowing) {
        _overlayController.hide();
      }
    });
  }

  void _hideImmediate() {
    _hideTimer?.cancel();
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
  }

  Future<void> _openMobileSheet(_ConnectionStateKind kind) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _ConnectionStatusPopover(
              kind: kind,
              onDismiss: () => Navigator.of(sheetContext).maybePop(),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(
      websocketProvider.select(
        (s) => (s.isConnected, s.reconnectAttempts, s.wasReplaced),
      ),
    );
    final kind = _kindFor(
      isConnected: ws.$1,
      reconnectAttempts: ws.$2,
      wasReplaced: ws.$3,
    );
    if (kind != _lastKind) {
      _lastKind = kind;
      // Defer to post-frame: MediaQuery isn't safe to read in build for
      // the controller side-effect, and the pulse state only needs to be
      // accurate within a frame of the kind change.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPulse(kind);
      });
    }

    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final dotColor = _dotColorFor(kind);
    final showPulse = kind == _ConnectionStateKind.reconnecting;
    final tooltipLabel = _titleFor(kind);

    final stack = Stack(
      key: _triggerKey,
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned(
          bottom: widget.dotInset.bottom,
          right: widget.dotInset.right,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) {
                // Outer pulse ring: opacity oscillates 0 -> 0.5 -> 0 over the
                // 1 s cycle, only while reconnecting.
                final t = _pulseController.value;
                final ringOpacity = showPulse
                    ? (0.5 * (1 - (2 * t - 1).abs()))
                    : 0.0;
                return Container(
                  width: widget.dotSize,
                  height: widget.dotSize,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.sidebarBg, width: 2),
                    boxShadow: [
                      if (ringOpacity > 0)
                        BoxShadow(
                          color: dotColor.withValues(alpha: ringOpacity),
                          blurRadius: 0,
                          spreadRadius: widget.dotSize * 0.5,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );

    // Mobile: keep the system tooltip (long-press hint). Desktop uses the
    // custom OverlayPortal popover, so we drop the tooltip to avoid the
    // double-hover affect (system tooltip overlaps + covers the popover).
    if (isMobile) {
      return Semantics(
        button: true,
        label: 'Connection status: $tooltipLabel',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openMobileSheet(kind),
          child: Tooltip(message: tooltipLabel, child: stack),
        ),
      );
    }

    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (overlayContext) {
        return _PopoverOverlay(
          triggerKey: _triggerKey,
          onMouseEnter: _showPopover,
          onMouseExit: _scheduleHide,
          child: _ConnectionStatusPopover(
            kind: kind,
            onDismiss: _hideImmediate,
          ),
        );
      },
      child: MouseRegion(
        onEnter: (_) => _showPopover(),
        onExit: (_) => _scheduleHide(),
        child: Semantics(
          button: true,
          label: 'Connection status: $tooltipLabel',
          child: stack,
        ),
      ),
    );
  }
}

/// Renders the popover content (state title, subtitle, optional action button,
/// and a collapsible diagnostics block). Used by both the desktop OverlayPortal
/// and the mobile bottom sheet.
class _ConnectionStatusPopover extends ConsumerStatefulWidget {
  final _ConnectionStateKind kind;
  final VoidCallback onDismiss;

  const _ConnectionStatusPopover({required this.kind, required this.onDismiss});

  @override
  ConsumerState<_ConnectionStatusPopover> createState() =>
      _ConnectionStatusPopoverState();
}

class _ConnectionStatusPopoverState
    extends ConsumerState<_ConnectionStatusPopover> {
  bool _showDiagnostics = false;

  String _diagnosticsText({
    required _ConnectionStateKind kind,
    required int attempts,
    required bool replaced,
    required String serverUrl,
    required TargetPlatform platform,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final version = appVersion;
    return [
      'Echo connection diagnostics',
      '---------------------------',
      'Time:        $now',
      'State:       ${_kindLabel(kind)}',
      'Server:      $serverUrl',
      'Reconnects:  $attempts / $_kReconnectingCutoff',
      'Replaced:    ${replaced ? 'yes' : 'no'}',
      'App version: $version',
      'Platform:    ${platform.name}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(
      websocketProvider.select((s) => (s.reconnectAttempts, s.wasReplaced)),
    );
    final attempts = ws.$1;
    final replaced = ws.$2;
    final serverUrl = ref.watch(serverUrlProvider);
    final kind = widget.kind;
    final dotColor = _dotColorFor(kind);
    final title = _titleFor(kind);
    final subtitle = _subtitleFor(kind, attempts);

    Widget? actionButton;
    if (kind == _ConnectionStateKind.reconnecting ||
        kind == _ConnectionStateKind.offline) {
      actionButton = FilledButton(
        onPressed: () {
          ref.read(websocketProvider.notifier).connect();
          widget.onDismiss();
        },
        child: const Text('Retry now'),
      );
    } else if (kind == _ConnectionStateKind.replaced) {
      actionButton = FilledButton(
        onPressed: () {
          ref.read(websocketProvider.notifier).reconnectAfterReplacement();
          widget.onDismiss();
        },
        child: const Text('Sign in here'),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: _kPopoverMaxWidth),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: context.textMuted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (actionButton != null) ...[
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: actionButton),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() {
                _showDiagnostics = !_showDiagnostics;
              }),
              icon: Icon(
                _showDiagnostics
                    ? Icons.expand_less_outlined
                    : Icons.expand_more_outlined,
                size: 16,
              ),
              label: Text(
                _showDiagnostics ? 'Hide diagnostics' : 'Show diagnostics',
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: _showDiagnostics
                  ? _DiagnosticsBlock(
                      kind: kind,
                      attempts: attempts,
                      replaced: replaced,
                      serverUrl: serverUrl,
                      onCopy: () async {
                        final text = _diagnosticsText(
                          kind: kind,
                          attempts: attempts,
                          replaced: replaced,
                          serverUrl: serverUrl,
                          platform: Theme.of(context).platform,
                        );
                        await Clipboard.setData(ClipboardData(text: text));
                        if (!context.mounted) return;
                        ToastService.show(
                          context,
                          'Diagnostics copied',
                          type: ToastType.success,
                        );
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsBlock extends StatelessWidget {
  final _ConnectionStateKind kind;
  final int attempts;
  final bool replaced;
  final String serverUrl;
  final Future<void> Function() onCopy;

  const _DiagnosticsBlock({
    required this.kind,
    required this.attempts,
    required this.replaced,
    required this.serverUrl,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'Server', serverUrl),
          _row(context, 'State', _kindLabel(kind)),
          _row(context, 'Reconnects', '$attempts / $_kReconnectingCutoff'),
          _row(context, 'Replaced', replaced ? 'yes' : 'no'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onCopy(),
              icon: const Icon(Icons.content_copy_outlined, size: 14),
              label: const Text('Copy diagnostics'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Positions the popover under the trigger and clamps to viewport bounds.
/// Renders an inner [MouseRegion] so the user can mouse from the trigger into
/// the popover without it dismissing.
class _PopoverOverlay extends StatelessWidget {
  final GlobalKey triggerKey;
  final VoidCallback onMouseEnter;
  final VoidCallback onMouseExit;
  final Widget child;

  const _PopoverOverlay({
    required this.triggerKey,
    required this.onMouseEnter,
    required this.onMouseExit,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final triggerCtx = triggerKey.currentContext;
    if (triggerCtx == null) return const SizedBox.shrink();
    final box = triggerCtx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);

    final preferredLeft = offset.dx;
    // Clamp: must stay within [padding, screen.width - popoverWidth - padding].
    final maxLeft = screen.width - _kPopoverMaxWidth - _kViewportPadding;
    final clampedLeft = preferredLeft.clamp(
      _kViewportPadding,
      maxLeft < _kViewportPadding ? _kViewportPadding : maxLeft,
    );
    final top = offset.dy + size.height + 6;

    return Positioned(
      left: clampedLeft.toDouble(),
      top: top,
      child: MouseRegion(
        onEnter: (_) => onMouseEnter(),
        onExit: (_) => onMouseExit(),
        child: child,
      ),
    );
  }
}
