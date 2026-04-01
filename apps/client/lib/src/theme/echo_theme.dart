import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class EchoTheme {
  // shadcn-inspired dark palette
  static const mainBg = Color(0xFF0A0A0B);
  static const sidebarBg = Color(0xFF0F0F10);
  static const chatBg = Color(0xFF141415);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceHover = Color(0xFF232326);
  static const accent = Color(0xFF6366F1);
  static const accentHover = Color(0xFF818CF8);
  static const accentLight = Color(0x1A6366F1);
  static const textPrimary = Color(0xFFEDEDEF);
  static const textSecondary = Color(0xFF8B8B8E);
  static const textMuted = Color(0xFF4B4B4F);
  static const sentBubble = Color(0xFF6366F1);
  static const recvBubble = Color(0xFF1C1C1E);
  static const border = Color(0xFF27272A);
  static const online = Color(0xFF22C55E);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);

  // Legacy aliases used by screens we are not rewriting (contacts, groups, etc.)
  static const background = mainBg;
  static const panelBg = sidebarBg;
  static const inputBg = surface;
  static const hoverBg = surfaceHover;
  static const activeBg = Color(0xFF27272A);
  static const divider = border;

  static ThemeData get darkTheme {
    final baseTextTheme = GoogleFonts.interTextTheme(
      ThemeData.dark().textTheme,
    );
    final textTheme = baseTextTheme.copyWith(
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: textPrimary,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: textPrimary,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.47,
        color: textPrimary,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textMuted,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: textSecondary,
      ),
    );

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: mainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accentHover,
        surface: surface,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: sidebarBg,
        foregroundColor: textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),
      dividerColor: border,
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: GoogleFonts.inter(color: textMuted, fontSize: 13),
        labelStyle: GoogleFonts.inter(color: textSecondary, fontSize: 13),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      iconTheme: const IconThemeData(color: textSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 1),
        ),
        textStyle: GoogleFonts.inter(color: textPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: GoogleFonts.inter(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
