import 'package:flutter/material.dart';

class EchoTheme {
  static const background = Color(0xFF1E1F22);
  static const panelBg = Color(0xFF2B2D31);
  static const chatBg = Color(0xFF313338);
  static const inputBg = Color(0xFF383A40);
  static const textPrimary = Color(0xFFF2F3F5);
  static const textSecondary = Color(0xFFB5BAC1);
  static const textMuted = Color(0xFF949BA4);
  static const accent = Color(0xFF5865F2);
  static const online = Color(0xFF23A55A);
  static const danger = Color(0xFFF23F43);
  static const warning = Color(0xFFF0B232);
  static const hoverBg = Color(0xFF2E3035);
  static const activeBg = Color(0xFF393C43);
  static const divider = Color(0xFF3F4147);

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: panelBg,
          error: danger,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: textPrimary,
          onError: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: panelBg,
          foregroundColor: textPrimary,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        dividerColor: divider,
        dividerTheme: const DividerThemeData(
          color: divider,
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
          fillColor: inputBg,
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
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accent),
        ),
        iconTheme: const IconThemeData(color: textSecondary, size: 20),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: const TextStyle(color: textPrimary, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
        ),
      );
}
