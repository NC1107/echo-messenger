import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/providers/auth_provider.dart';
import 'src/providers/crypto_provider.dart';

/// Launch with env vars for auto-login:
///   ECHO_USERNAME=alice ECHO_PASSWORD=password123 ./echo_app
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? argUsername;
  String? argPassword;
  String? argServer;

  // Parse env vars for auto-login (desktop only, not web)
  if (!kIsWeb) {
    try {
      // Dynamic import to avoid dart:io on web
      argUsername = const String.fromEnvironment('ECHO_USERNAME') != ''
          ? const String.fromEnvironment('ECHO_USERNAME')
          : null;
      argPassword = const String.fromEnvironment('ECHO_PASSWORD') != ''
          ? const String.fromEnvironment('ECHO_PASSWORD')
          : null;
      argServer = const String.fromEnvironment('ECHO_SERVER') != ''
          ? const String.fromEnvironment('ECHO_SERVER')
          : null;
    } catch (_) {}
  }

  final container = ProviderContainer();

  // Auto-login if credentials provided
  if (argUsername != null && argPassword != null) {
    final auth = container.read(authProvider.notifier);
    if (argServer != null) auth.setServerUrl(argServer);
    await auth.login(argUsername, argPassword);

    if (container.read(authProvider).isLoggedIn) {
      await container.read(cryptoProvider.notifier).initAndUploadKeys();
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const EchoApp(),
    ),
  );
}
