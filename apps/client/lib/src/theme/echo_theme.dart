import 'package:flutter/material.dart';

class EchoTheme {
  // Clean dark palette -- generous spacing, not cramped
  static const mainBg = Color(0xFF191919);
  static const sidebarBg = Color(0xFF1E1E1E);
  static const chatBg = Color(0xFF252525);
  static const surface = Color(0xFF2A2A2A);
  static const accent = Color(0xFF0057FF);
  static const accentLight = Color(0x200057FF);
  static const textPrimary = Color(0xFFF0F0F0);
  static const textSecondary = Color(0xFF888888);
  static const textMuted = Color(0xFF555555);
  static const sentBubble = Color(0xFF0057FF);
  static const recvBubble = Color(0xFF2A2A2A);
  static const border = Color(0xFF333333);
  static const online = Color(0xFF44CC44);
  static const danger = Color(0xFFF23F43);
  static const warning = Color(0xFFF0B232);

  // Legacy aliases used by screens we are not rewriting (contacts, groups, etc.)
  static const background = mainBg;
  static const panelBg = sidebarBg;
  static const inputBg = surface;
  static const hoverBg = Color(0xFF2E2E2E);
  static const activeBg = Color(0xFF333333);
  static const divider = border;

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: mainBg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: sidebarBg,
          error: danger,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: textPrimary,
          onError: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: sidebarBg,
          foregroundColor: textPrimary,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        dividerColor: border,
        dividerTheme: const DividerThemeData(
          color: border,
          thickness: 1,
          space: 1,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
          headlineMedium: TextStyle(
            color: textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
          titleLarge: TextStyle(
            color: textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          titleMedium: TextStyle(
            color: textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 16),
          bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
          bodySmall: TextStyle(color: textMuted, fontSize: 12),
          labelLarge: TextStyle(
            color: textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          hintStyle: const TextStyle(color: textMuted, fontSize: 14),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accent),
        ),
        iconTheme: const IconThemeData(color: textSecondary, size: 20),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: mainBg,
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: const TextStyle(color: textPrimary, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
        ),
      );
}
