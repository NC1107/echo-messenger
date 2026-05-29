import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/canvas_models.dart' show CanvasAttachState;
import '../../providers/canvas_provider.dart';
import '../../theme/echo_theme.dart';

const Duration _kSlowConnectionThreshold = Duration(seconds: 8);

/// Non-blocking banner shown at the top of the voice-lounge canvas while the
/// initial snapshot is being fetched from the server.
///
/// States:
/// - [CanvasAttachState.idle] / [CanvasAttachState.loaded] → hidden.
/// - [CanvasAttachState.loading] → spinner + "Catching up…". After 8 s
///   without state change the text updates to "Slow connection — still
///   loading…".
/// - [CanvasAttachState.failed] → error message + retry button.
class CanvasLoadingBanner extends ConsumerStatefulWidget {
  const CanvasLoadingBanner({super.key});

  @override
  ConsumerState<CanvasLoadingBanner> createState() =>
      _CanvasLoadingBannerState();
}

class _CanvasLoadingBannerState extends ConsumerState<CanvasLoadingBanner> {
  Timer? _slowTimer;
  bool _isSlow = false;

  @override
  void initState() {
    super.initState();
    // Seed the timer for the initial state (e.g. if the widget is mounted
    // while loading is already in progress).
    final s = ref.read(canvasProvider);
    if (s.attachState == CanvasAttachState.loading) {
      _armSlowTimer(s.attachStartedAt);
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  /// Arms the slow-connection timer relative to [startedAt].
  /// Cancels any existing timer first so re-attach cycles start fresh.
  void _armSlowTimer(DateTime? startedAt) {
    _slowTimer?.cancel();
    _isSlow = false;

    if (startedAt == null) return;

    final elapsed = DateTime.now().difference(startedAt);
    final remaining = _kSlowConnectionThreshold - elapsed;

    if (remaining <= Duration.zero) {
      _isSlow = true;
      return;
    }

    _slowTimer = Timer(remaining, () {
      if (mounted) setState(() => _isSlow = true);
    });
  }

  void _cancelSlowTimer() {
    _slowTimer?.cancel();
    _slowTimer = null;
    _isSlow = false;
  }

  @override
  Widget build(BuildContext context) {
    // Listen for attach-state transitions to arm / cancel the slow timer as
    // a side-effect (not inline in build, which would re-arm on every rebuild).
    ref.listen<CanvasAttachState>(canvasProvider.select((s) => s.attachState), (
      prev,
      next,
    ) {
      if (next == CanvasAttachState.loading) {
        final startedAt = ref.read(
          canvasProvider.select((s) => s.attachStartedAt),
        );
        _armSlowTimer(startedAt);
      } else {
        _cancelSlowTimer();
      }
    });

    final attachState = ref.watch(canvasProvider.select((s) => s.attachState));

    if (attachState == CanvasAttachState.idle ||
        attachState == CanvasAttachState.loaded) {
      return const SizedBox.shrink();
    }

    if (attachState == CanvasAttachState.loading) {
      return _buildLoading(context);
    }

    // failed
    return _buildFailed(context);
  }

  Widget _buildLoading(BuildContext context) {
    final label = _isSlow ? 'Slow connection — still loading…' : 'Catching up…';

    return _BannerShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(context.accent),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailed(BuildContext context) {
    return _BannerShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: context.accent),
          const SizedBox(width: 8),
          Text(
            "Couldn't load canvas",
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => ref.read(canvasProvider.notifier).retryAttach(),
            style: TextButton.styleFrom(
              foregroundColor: context.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(44, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Retry',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerShell extends StatelessWidget {
  const _BannerShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.border),
      ),
      child: child,
    );
  }
}
