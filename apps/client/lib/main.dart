import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'src/app.dart';
import 'src/providers/server_url_provider.dart';
import 'src/services/debug_log_service.dart';
import 'src/services/message_cache.dart';
import 'src/services/notification_service.dart';
import 'src/services/saved_messages_service.dart';
import 'src/services/sound_service.dart';
import 'src/services/user_data_dir.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global error boundary: catch unhandled Flutter framework errors so that
  // the red error screen is never shown in production.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    DebugLogService.instance.log(
      LogLevel.error,
      'FlutterError',
      '${details.exceptionAsString()}\n${details.stack}',
    );
  };

  // Catch async errors not handled by the Flutter framework.
  runZonedGuarded(
    () async {
      await _initAndRun();
    },
    (error, stack) {
      debugPrint('[Unhandled] $error\n$stack');
      DebugLogService.instance.log(
        LogLevel.error,
        'Unhandled',
        '$error\n$stack',
      );
    },
  );
}

Future<void> _initAndRun() async {
  await Hive.initFlutter();
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

  // Request browser notification permission (no-op on non-web platforms).
  // Awaited so that the permission flag is set before any messages arrive.
  await NotificationService().requestPermission();

  // Auto-login + crypto init is handled by SplashScreen
  runApp(
    UncontrolledProviderScope(container: container, child: const EchoApp()),
  );
}
