import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/providers/auth_provider.dart';
import 'src/providers/crypto_provider.dart';
import 'src/providers/server_url_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();

  // Load persisted server URL before any network calls
  await container.read(serverUrlProvider.notifier).load();

  final auth = container.read(authProvider.notifier);

  // Try auto-login from stored credentials (SharedPreferences)
  final autoLoggedIn = await auth.tryAutoLogin();

  // If auto-login worked, init crypto
  if (autoLoggedIn) {
    await container.read(cryptoProvider.notifier).initAndUploadKeys();
  }

  // Also support compile-time env vars (for CI/testing)
  if (!autoLoggedIn && !kIsWeb) {
    final envUser = const String.fromEnvironment('ECHO_USERNAME');
    final envPass = const String.fromEnvironment('ECHO_PASSWORD');
    if (envUser.isNotEmpty && envPass.isNotEmpty) {
      await auth.login(envUser, envPass);
      if (container.read(authProvider).isLoggedIn) {
        await container.read(cryptoProvider.notifier).initAndUploadKeys();
      }
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const EchoApp(),
    ),
  );
}
