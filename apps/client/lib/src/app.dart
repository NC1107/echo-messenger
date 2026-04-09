import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/accessibility_provider.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/echo_theme.dart';

class EchoApp extends ConsumerWidget {
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeSelection = ref.watch(themeProvider);
    final accessibility = ref.watch(accessibilityProvider);

    final themeMode = switch (themeSelection) {
      AppThemeSelection.system => ThemeMode.system,
      AppThemeSelection.dark => ThemeMode.dark,
      AppThemeSelection.light => ThemeMode.light,
      AppThemeSelection.graphite => ThemeMode.dark,
      AppThemeSelection.ember => ThemeMode.dark,
      AppThemeSelection.neon => ThemeMode.dark,
      AppThemeSelection.sakura => ThemeMode.light,
    };
    final darkTheme = switch (themeSelection) {
      AppThemeSelection.graphite => EchoTheme.graphiteTheme,
      AppThemeSelection.ember => EchoTheme.emberTheme,
      AppThemeSelection.neon => EchoTheme.neonTheme,
      _ => EchoTheme.darkTheme,
    };
    final lightTheme = switch (themeSelection) {
      AppThemeSelection.sakura => EchoTheme.sakuraTheme,
      _ =>
        accessibility.highContrast
            ? EchoTheme.highContrastLightTheme
            : EchoTheme.lightTheme,
    };

    return MaterialApp.router(
      title: 'Echo',
      theme: lightTheme,
      darkTheme: accessibility.highContrast
          ? EchoTheme.highContrastDarkTheme
          : darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // Apply font-scale and reduced-motion overrides via MaterialApp builder.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(accessibility.fontScale),
            disableAnimations:
                accessibility.reducedMotion || mq.disableAnimations,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
