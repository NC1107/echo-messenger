import 'dart:async';
import 'dart:io' show Directory, Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/providers/server_url_provider.dart';
import 'src/providers/websocket_provider.dart';
import 'src/services/app_lifecycle_logger.dart';
import 'src/services/debug_log_service.dart';
import 'src/services/message_cache.dart';
import 'src/services/notification_service.dart';
import 'src/services/saved_messages_service.dart';
import 'src/services/sound_service.dart';
import 'src/services/user_data_dir.dart';
import 'src/services/window_state_service.dart';
import 'src/utils/platform_shutdown.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize media_kit's libmpv backend so video playback works on every
  // platform — including Linux desktop, where Flutter's default video_player
  // has no implementation (#727).
  MediaKit.ensureInitialized();

  // Cap Flutter's in-memory decoded-image cache.
  // Web holds decoded bitmaps in the JS heap, so 100 MB risks browser OOM
  // under memory pressure — drop to 30 MB / 200 images there (#1117).
  // Native keeps the original 500 / 100 MB.
  PaintingBinding.instance.imageCache.maximumSize = kIsWeb ? 200 : 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = kIsWeb
      ? 30 * 1024 * 1024
      : 100 * 1024 * 1024;

  // Register lifecycle observer early — before runApp — so it captures state
  // changes that happen during voice-channel entry on iOS (audio session
  // activation can trigger lifecycle events before the first frame).
  // AppLifecycleLogger also implements didRequestAppExit to flush logs before
  // a graceful process exit.
  const lifecycleLogger = AppLifecycleLogger();
  WidgetsBinding.instance.addObserver(lifecycleLogger);

  // Catch unhandled Flutter framework errors (widget build errors, assertion
  // failures, etc.). Using LogLevel.fatal so these stand out in the log
  // viewer — framework errors almost always indicate a crash or a broken
  // widget tree.
  FlutterError.onError = (details) {
    DebugLogService.instance.log(
      LogLevel.fatal,
      'flutter',
      '${details.exception}\n${details.stack}',
    );
    // Synchronous write — async forceFlush risks losing the fatal entry to
    // SIGKILL on iOS hard-crashes before the microtask runs.
    DebugLogService.instance.forceFlushSync();
    FlutterError.presentError(details);
  };

  // Catch uncaught async errors that escape the Flutter framework (Dart
  // Isolate, dart:async Future chains, platform channel callbacks).
  // Returns true to signal that the error was handled and should not be
  // re-thrown by the engine.
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLogService.instance.log(LogLevel.fatal, 'platform', '$error\n$stack');
    DebugLogService.instance.forceFlushSync();
    return true;
  };

  // Catch async errors not handled by either of the two handlers above.
  // runZonedGuarded provides a final safety net for errors thrown inside
  // the zone but outside a Flutter frame (e.g. timers, streams).
  runZonedGuarded(
    () async {
      await _initAndRun();
    },
    (error, stack) {
      debugPrint('[Unhandled] $error\n$stack');
      DebugLogService.instance.log(
        LogLevel.fatal,
        'platform',
        '$error\n$stack',
      );
      DebugLogService.instance.forceFlushSync();
    },
  );
}

/// Initialize Hive with a sane storage location.
///
/// `Hive.initFlutter()` calls `getApplicationDocumentsDirectory()` which on
/// Linux desktop resolves to `~/Documents/` -- the user's general-purpose
/// folder, not an app-private dir.  That dumps `echo_*.hive` and `.lock`
/// files alongside the user's own documents.  On Linux we route to
/// `getApplicationSupportDirectory()` (`~/.local/share/<bundle>/`) instead.
/// Other platforms keep the default since their app-documents path is
/// already private (e.g. `~/Library/Containers/<bundle>/Data/Documents`
/// on macOS, `AppData\Roaming\<vendor>\<app>` on Windows).
Future<void> _initHive() async {
  if (kIsWeb || !Platform.isLinux) {
    await Hive.initFlutter();
    return;
  }
  final appSupport = await getApplicationSupportDirectory();
  final hiveDir = p.join(appSupport.path, 'hive');
  await Directory(hiveDir).create(recursive: true);
  Hive.init(hiveDir);
}

Future<void> _initAndRun() async {
  await _initHive();
  await UserDataDir.instance.init();
  await MessageCache.init();
  await SavedMessagesService.instance.init();

  final container = ProviderContainer();

  // Load persisted server URL before any network calls
  await container.read(serverUrlProvider.notifier).load();

  // For web: enable semantics tree so Playwright E2E tests can use
  // ARIA locators (getByRole, getByLabel) instead of pixel coordinates.
  // Also check URL query params for server URL override.
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();

    final serverParam = Uri.base.queryParameters['server'];
    if (serverParam != null && serverParam.isNotEmpty) {
      await container.read(serverUrlProvider.notifier).setUrl(serverParam);
    }
  }

  // Load persisted sound preference
  await SoundService().init();

  // Pre-load the Inter font family (all UI weights) before first frame so
  // text never renders in the platform fallback while a weight downloads.
  await GoogleFonts.pendingFonts([
    GoogleFonts.inter(fontWeight: FontWeight.w400),
    GoogleFonts.inter(fontWeight: FontWeight.w500),
    GoogleFonts.inter(fontWeight: FontWeight.w600),
    GoogleFonts.inter(fontWeight: FontWeight.w700),
  ]);

  // Sync browser notification permission state (granted/denied) without
  // prompting. The actual permission dialog is shown later from a user
  // gesture (e.g. the notification settings toggle).
  await NotificationService().requestPermission();

  // SIGTERM handler: catches `kill -TERM <pid>` and host shutdown events
  // (systemd sends SIGTERM before SIGKILL).  Fires cleanup before exit so
  // the WebSocket gets a proper close frame and Hive writes are flushed.
  // Web and Windows do not support POSIX signals; handled there via the
  // AppLifecycleState.detached path in ShutdownHandler.
  if (!kIsWeb) {
    registerSigtermHandler(() => _performCleanup(container));
  }

  // Auto-login + crypto init is handled by SplashScreen
  // Issue #481: Linux GTK resize triangle (bottom-right corner) bleeds
  // through Flutter canvas on some compositors. This is a Flutter Linux
  // platform limitation with no clean Dart-side fix. Unaffected on web,
  // macOS, Windows. Track: https://github.com/flutter/flutter/issues/...
  runApp(
    UncontrolledProviderScope(container: container, child: const EchoApp()),
  );
}

/// Performs the shared pre-termination cleanup steps:
///   1. Sends a WebSocket close frame (server marks user offline immediately).
///   2. Begins flushing Hive box files to disk (fire-and-forget — cannot await
///      because the caller may call exit(0) synchronously after this returns).
void _performCleanup(ProviderContainer container) {
  try {
    container.read(websocketProvider.notifier).disconnect();
  } catch (_) {}
  try {
    // Slice 10: capture last-known window geometry before quitting so the
    // next launch restores it after the splash. Fire-and-forget so we
    // never block the SIGTERM cleanup path.
    WindowStateService.save().ignore();
  } catch (_) {}
  try {
    // #1182: kick a fire-and-forget flush on the message-cache boxes
    // before the close. SIGTERM gives systemd ~5s to clean up; even a
    // partial flush is better than zero, and the no-await-required
    // ShutdownHandler.paused path will already have flushed in most
    // graceful shutdown sequences. This catches the SIGKILL-after-no-
    // -paused (web exit, IDE force-quit) case.
    MessageCache.flushAll().ignore();
  } catch (_) {}
  try {
    // Hive.close() is async; starting it before exit(0) gives Hive a chance
    // to begin flushing buffered writes, which prevents box-file corruption
    // on graceful SIGTERM paths.
    Hive.close().ignore();
  } catch (_) {}
}
