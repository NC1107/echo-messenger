import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import 'debug_log_service.dart';

/// Observes [AppLifecycleState] transitions and writes a breadcrumb for each
/// change via [DebugLogService].
///
/// Register an instance with [WidgetsBinding.instance.addObserver] early in
/// [main] — before [runApp] — so the observer captures state changes that
/// occur during app startup and voice-channel entry on iOS, where the audio
/// session activation can trigger lifecycle events before the first frame.
///
/// Each lifecycle event is logged at [LogLevel.info]. For states that are
/// close to the process going away (paused, detached, hidden) the write is
/// force-flushed immediately so the breadcrumb survives even if the OS kills
/// the process within milliseconds.
///
/// [didRequestAppExit] is also implemented to flush logs before a graceful
/// exit initiated by the platform (e.g. desktop close button, iOS swipe-up
/// force-quit).
class AppLifecycleLogger with WidgetsBindingObserver {
  const AppLifecycleLogger();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Skip resumed/inactive — they fire every time the window loses or
    // regains focus (clicking outside the app and back), drowning out the
    // useful entries. Paused / detached / hidden are the breadcrumbs that
    // actually matter for triage because they mean the OS is about to kill
    // the process. (#1128)
    final needsImmediateFlush =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;

    if (!needsImmediateFlush) return;

    DebugLogService.instance.log(
      LogLevel.info,
      'Lifecycle',
      'state=${state.name}',
    );
    DebugLogService.instance.forceFlush().ignore();
  }

  /// Called by the framework when the platform requests the app to exit
  /// gracefully (e.g. desktop close button, iOS swipe-up force-quit).
  /// Flush logs to disk before allowing the exit to proceed.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await DebugLogService.instance.forceFlush();
    return AppExitResponse.exit;
  }
}
