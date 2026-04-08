import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'src/app.dart';
import 'src/providers/server_url_provider.dart';
import 'src/services/message_cache.dart';
import 'src/services/notification_service.dart';
import 'src/services/sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  await MessageCache.init();

  final container = ProviderContainer();

  // Load persisted server URL before any network calls
  await container.read(serverUrlProvider.notifier).load();

  // For web: check URL query params to allow overriding the server URL
  if (kIsWeb) {
    await BrowserContextMenu.disableContextMenu();

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
