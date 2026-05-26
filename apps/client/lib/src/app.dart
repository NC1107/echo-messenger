import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/accessibility_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/echo_theme.dart';
import 'widgets/biometric_lock_guard.dart';
import 'widgets/shutdown_handler.dart';

/// Applies [CustomColorsState] overrides to an existing [ThemeData].
/// Only overrides fields when a custom color is actually set; falls back
/// to the theme's current values otherwise.
ThemeData _applyCustomColors(ThemeData base, CustomColorsState custom) {
  if (!custom.hasOverrides) return base;
  final scheme = base.colorScheme;
  // `context.accent` (the dominant accent reader, ~270 callsites) is
  // wired to `colorScheme.primary`, so the user's accent override must
  // land there for the picker to actually move the UI.
  final accent = custom.accentColor ?? scheme.primary;
  final secondary = custom.primaryColor ?? scheme.secondary;
  final onAccent =
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
      ? Colors.white
      : Colors.black;
  final onSecondary =
      ThemeData.estimateBrightnessForColor(secondary) == Brightness.dark
      ? Colors.white
      : Colors.black;
  final echoExt = base.extension<EchoColorExtension>();
  final updatedEcho = echoExt?.copyWith(
    sentBubble: accent,
    accentLight: accent.withValues(alpha: 0.2),
  );
  return base.copyWith(
    colorScheme: scheme.copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondary: secondary,
      onSecondary: onSecondary,
    ),
    extensions: [
      ...base.extensions.values.where((e) => e is! EchoColorExtension),
      ?updatedEcho,
    ],
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
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
      AppThemeSelection.indigo => ThemeMode.dark,
      AppThemeSelection.paper => ThemeMode.light,
      AppThemeSelection.graphite => ThemeMode.dark,
      AppThemeSelection.ember => ThemeMode.dark,
      AppThemeSelection.sakura => ThemeMode.light,
      AppThemeSelection.highContrast => ThemeMode.dark,
    };
    final darkThemeBase = switch (themeSelection) {
      AppThemeSelection.graphite => EchoTheme.graphiteTheme,
      AppThemeSelection.ember => EchoTheme.emberTheme,
      AppThemeSelection.highContrast => EchoTheme.highContrastTheme,
      _ => EchoTheme.darkTheme,
    };
    final lightThemeBase = switch (themeSelection) {
      AppThemeSelection.sakura => EchoTheme.sakuraTheme,
      AppThemeSelection.highContrast => EchoTheme.highContrastTheme,
      _ =>
        accessibility.highContrast
            ? EchoTheme.highContrastTheme
            : EchoTheme.lightTheme,
    };

    // Apply user-defined color overrides on top of the selected theme.
    // The accessibility.highContrast toggle still forces HC regardless of the
    // theme selection (overlay behavior, independent of the picker).
    final darkTheme = _applyCustomColors(
      accessibility.highContrast ? EchoTheme.highContrastTheme : darkThemeBase,
      customColors,
    );
    final lightTheme = _applyCustomColors(lightThemeBase, customColors);

    return MaterialApp.router(
      title: 'Echo',
      locale: locale,
      supportedLocales: supportedFlutterLocales,
      // When app-specific delegates (e.g. AppLocalizations.delegate from
      // gen_l10n) are added later, they MUST come BEFORE the Global* entries
      // so user-supplied strings can override Flutter defaults.
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
        return ShutdownHandler(child: BiometricLockGuard(child: inner));
      },
    );
  }
}
