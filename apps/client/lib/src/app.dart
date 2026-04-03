import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/echo_theme.dart';

class EchoApp extends ConsumerWidget {
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeSelection = ref.watch(themeProvider);
    final themeMode = switch (themeSelection) {
      AppThemeSelection.system => ThemeMode.system,
      AppThemeSelection.dark => ThemeMode.dark,
      AppThemeSelection.light => ThemeMode.light,
      AppThemeSelection.graphite => ThemeMode.dark,
      AppThemeSelection.ember => ThemeMode.dark,
    };
    final darkTheme = switch (themeSelection) {
      AppThemeSelection.graphite => EchoTheme.graphiteTheme,
      AppThemeSelection.ember => EchoTheme.emberTheme,
      _ => EchoTheme.darkTheme,
    };

    return MaterialApp.router(
      title: 'Echo',
      theme: EchoTheme.lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
