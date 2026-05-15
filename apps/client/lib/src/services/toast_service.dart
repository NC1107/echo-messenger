import 'dart:async';

import 'package:flutter/material.dart';

import '../services/debug_log_service.dart';
import '../theme/echo_theme.dart';

enum ToastType { success, error, info, warning }

class ToastService {
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  /// Show a toast. Optionally include an inline action button (rendered to
  /// the right of the message) that calls [onAction] then dismisses. When
  /// [actionLabel] is set, the toast defaults to a 6-second duration unless
  /// [duration] is provided explicitly.
  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    // Mirror error and warning toasts into the debug log so they are always
    // visible in Settings > Debug Logs, even if the on-screen toast was missed.
    if (type == ToastType.error) {
      DebugLogService.instance.log(LogLevel.error, 'UI', message);
    } else if (type == ToastType.warning) {
      DebugLogService.instance.log(LogLevel.warning, 'UI', message);
    }

    // Remove any existing toast immediately.
    _dismiss();

    final overlay = Overlay.of(context);

    final hasAction = actionLabel != null;
    final effectiveDuration =
        duration ??
        (hasAction ? const Duration(seconds: 6) : const Duration(seconds: 3));

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        type: type,
        actionLabel: actionLabel,
        onAction: onAction,
        totalDuration: effectiveDuration,
        onDismiss: () {
          _dismiss();
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    _dismissTimer = Timer(effectiveDuration, _dismiss);
  }

  static void _dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration totalDuration;

  const _ToastWidget({
    required this.message,
    required this.type,
    required this.onDismiss,
    required this.totalDuration,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();

    // Start fade-out 500ms before the auto-dismiss timer fires so the
    // reverse animation has time to complete before the entry is removed.
    final fadeStart = widget.totalDuration - const Duration(milliseconds: 500);
    Future.delayed(fadeStart.isNegative ? Duration.zero : fadeStart, () {
      if (mounted) {
        _controller.reverse().then((_) {
          if (mounted) widget.onDismiss();
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _backgroundColor(BuildContext context) {
    switch (widget.type) {
      case ToastType.success:
        return EchoTheme.online;
      case ToastType.error:
        return EchoTheme.danger;
      case ToastType.warning:
        return EchoTheme.warning;
      case ToastType.info:
        return context.accent;
    }
  }

  IconData _icon() {
    switch (widget.type) {
      case ToastType.success:
        return Icons.check_circle_outline;
      case ToastType.error:
        return Icons.close;
      case ToastType.warning:
        return Icons.warning_amber_rounded;
      case ToastType.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final actionLabel = widget.actionLabel;
    return Positioned(
      bottom: 24,
      right: 24,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _opacity,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 360),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _backgroundColor(context),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon(), size: 14, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  if (actionLabel != null) ...[
                    const SizedBox(width: 10),
                    Semantics(
                      label: actionLabel.toLowerCase(),
                      button: true,
                      child: GestureDetector(
                        onTap: () {
                          widget.onAction?.call();
                          widget.onDismiss();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Text(
                            actionLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: widget.onDismiss,
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
