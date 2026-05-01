import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/accessibility_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/echo_theme.dart';
import 'widgets/biometric_lock_guard.dart';

/// Applies [CustomColorsState] overrides to an existing [ThemeData].
/// Only overrides fields when a custom color is actually set; falls back
/// to the theme's current values otherwise.
ThemeData _applyCustomColors(ThemeData base, CustomColorsState custom) {
  if (!custom.hasOverrides) return base;
  final scheme = base.colorScheme;
  final primary = custom.primaryColor ?? scheme.primary;
  final accent = custom.accentColor ?? scheme.secondary;
  return base.copyWith(
    colorScheme: scheme.copyWith(primary: primary, secondary: accent),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: scheme.onPrimary,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent, width: 1),
      ),
    ),
  );
}

class EchoApp extends ConsumerWidget {
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeSelection = ref.watch(themeProvider);
    final accessibility = ref.watch(accessibilityProvider);
    final customColors = ref.watch(customColorsProvider);
    final locale = ref.watch(localeProvider);

    final themeMode = switch (themeSelection) {
      AppThemeSelection.system => ThemeMode.system,
      AppThemeSelection.dark => ThemeMode.dark,
      AppThemeSelection.light => ThemeMode.light,
      AppThemeSelection.graphite => ThemeMode.dark,
      AppThemeSelection.ember => ThemeMode.dark,
      AppThemeSelection.neon => ThemeMode.dark,
      AppThemeSelection.aurora => ThemeMode.dark,
      AppThemeSelection.sakura => ThemeMode.light,
    };
    final darkThemeBase = switch (themeSelection) {
      AppThemeSelection.graphite => EchoTheme.graphiteTheme,
      AppThemeSelection.ember => EchoTheme.emberTheme,
      AppThemeSelection.neon => EchoTheme.neonTheme,
      AppThemeSelection.aurora => EchoTheme.auroraTheme,
      _ => EchoTheme.darkTheme,
    };
    final lightThemeBase = switch (themeSelection) {
      AppThemeSelection.sakura => EchoTheme.sakuraTheme,
      _ =>
        accessibility.highContrast
            ? EchoTheme.highContrastLightTheme
            : EchoTheme.lightTheme,
    };

    // Apply user-defined color overrides on top of the selected theme.
    final darkTheme = _applyCustomColors(
      accessibility.highContrast
          ? EchoTheme.highContrastDarkTheme
          : darkThemeBase,
      customColors,
    );
    final lightTheme = _applyCustomColors(lightThemeBase, customColors);

    return MaterialApp.router(
      title: 'Echo',
      locale: locale,
      supportedLocales: supportedFlutterLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // Apply font-scale and reduced-motion overrides via MaterialApp builder.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final inner = MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(accessibility.fontScale),
            disableAnimations:
                accessibility.reducedMotion || mq.disableAnimations,
          ),
          child: child ?? const SizedBox.shrink(),
        );
        return BiometricLockGuard(child: inner);
      },
    );
  }
}
