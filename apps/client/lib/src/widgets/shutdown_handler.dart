import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../providers/websocket_provider.dart';
import '../services/message_cache.dart';

/// Wraps the widget tree with a lifecycle observer that performs a graceful
/// shutdown when the OS requests app termination.
///
/// On desktop platforms this covers:
///   - Linux: `SIGTERM` from systemd/shutdown → GApplication lifecycle →
///     `AppLifecycleState.detached`
///   - Windows: `WM_QUERYENDSESSION` / `WM_CLOSE` → `detached`
///   - macOS: `applicationShouldTerminate` → `detached`
///
/// `SIGTERM` is additionally intercepted in `main.dart` via
/// `ProcessSignal.sigterm` so that cleanup fires even when the GLib main loop
/// exits before the Dart lifecycle event is delivered.
///
/// On cleanup:
///   1. Send a WebSocket close frame (clean WS goodbye, prevents dirty
///      reconnect state on next launch).
///   2. Flush pending Hive writes (`Hive.close()`, best-effort).
class ShutdownHandler extends ConsumerStatefulWidget {
  const ShutdownHandler({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShutdownHandler> createState() => _ShutdownHandlerState();
}

class _ShutdownHandlerState extends ConsumerState<ShutdownHandler>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pre-instantiate so OS-shutdown handler doesn't race provider creation against dispose.
    ref.read(websocketProvider.notifier);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    switch (lifecycleState) {
      case AppLifecycleState.paused:
        // `paused` is the OS warning that we're about to be backgrounded /
        // terminated, but we can still safely await. Use the breathing room
        // to flush message-cache writes to disk — once `detached` fires we
        // can only fire-and-forget Hive.close(), and a hard kill mid-write
        // would otherwise corrupt the cache box (#1182).
        unawaited(MessageCache.flushAll());
      case AppLifecycleState.detached:
        _handleShutdown();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _handleShutdown() {
    // 1. Send WebSocket close frame so the server marks the user offline
    //    immediately instead of waiting for the idle-timeout sweep.
    try {
      ref.read(websocketProvider.notifier).disconnect();
    } catch (_) {
      // Provider may already be disposed during forced teardown — ignore.
    }

    // 2. Fire-and-forget Hive.close (sync callback can't await); the
    //    `paused` branch above already flushed pending writes, so the
    //    in-flight close window is minimal.
    Hive.close().ignore();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
