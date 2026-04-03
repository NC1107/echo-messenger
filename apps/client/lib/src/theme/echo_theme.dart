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
  static const textMuted = Color(0xFF6B6B6F);
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
      extensions: const [EchoColorExtension.dark],
      scaffoldBackgroundColor: mainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accentHover,
        surface: surface,
        onSurfaceVariant: textSecondary,
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
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }

  // Light theme colors
  static const lightMainBg = Color(0xFFF8F8FA);
  static const lightSidebarBg = Color(0xFFFFFFFF);
  static const lightChatBg = Color(0xFFF2F2F5);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceHover = Color(0xFFF0F0F2);
  static const lightTextPrimary = Color(0xFF18181B);
  static const lightTextSecondary = Color(0xFF71717A);
  static const lightTextMuted = Color(0xFFA1A1AA);
  static const lightSentBubble = Color(0xFF6366F1);
  static const lightRecvBubble = Color(0xFFE4E4E7);
  static const lightBorder = Color(0xFFE4E4E7);
  static const lightAccentLight = Color(0x1A6366F1);

  // Graphite theme colors (high-contrast dark with teal accent)
  static const graphiteMainBg = Color(0xFF0B1114);
  static const graphiteSidebarBg = Color(0xFF101A1F);
  static const graphiteChatBg = Color(0xFF142026);
  static const graphiteSurface = Color(0xFF1A2A32);
  static const graphiteSurfaceHover = Color(0xFF22363F);
  static const graphiteAccent = Color(0xFF14B8A6);
  static const graphiteAccentHover = Color(0xFF2DD4BF);
  static const graphiteAccentLight = Color(0x1A14B8A6);
  static const graphiteTextPrimary = Color(0xFFE7F4F8);
  static const graphiteTextSecondary = Color(0xFFA3BAC2);
  static const graphiteTextMuted = Color(0xFF6F8790);
  static const graphiteSentBubble = Color(0xFF0FA594);
  static const graphiteRecvBubble = Color(0xFF22333B);
  static const graphiteBorder = Color(0xFF2C434D);

  static ThemeData get lightTheme {
    final baseTextTheme = GoogleFonts.interTextTheme(
      ThemeData.light().textTheme,
    );
    final textTheme = baseTextTheme.copyWith(
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: lightTextPrimary,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: lightTextPrimary,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: lightTextPrimary,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: lightTextPrimary,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.47,
        color: lightTextPrimary,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: lightTextSecondary,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: lightTextMuted,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: lightTextSecondary,
      ),
    );

    return ThemeData(
      brightness: Brightness.light,
      extensions: const [EchoColorExtension.light],
      scaffoldBackgroundColor: lightMainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.light(
        primary: accent,
        secondary: accentHover,
        surface: lightSurface,
        onSurfaceVariant: lightTextSecondary,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: lightTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: lightSidebarBg,
        foregroundColor: lightTextPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: lightTextPrimary,
        ),
      ),
      dividerColor: lightBorder,
      dividerTheme: const DividerThemeData(
        color: lightBorder,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: lightBorder, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: lightBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: GoogleFonts.inter(color: lightTextMuted, fontSize: 13),
        labelStyle: GoogleFonts.inter(color: lightTextSecondary, fontSize: 13),
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
          foregroundColor: lightTextPrimary,
          side: const BorderSide(color: lightBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      iconTheme: const IconThemeData(color: lightTextSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: lightSurface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: lightBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: GoogleFonts.inter(color: lightTextPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: lightBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: lightSurface,
        contentTextStyle: GoogleFonts.inter(
          color: lightTextPrimary,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }

  static ThemeData get graphiteTheme {
    final baseTextTheme = GoogleFonts.interTextTheme(
      ThemeData.dark().textTheme,
    );
    final textTheme = baseTextTheme.copyWith(
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: graphiteTextPrimary,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: graphiteTextPrimary,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: graphiteTextPrimary,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: graphiteTextPrimary,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.47,
        color: graphiteTextPrimary,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: graphiteTextSecondary,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: graphiteTextMuted,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: graphiteTextSecondary,
      ),
    );

    return ThemeData(
      brightness: Brightness.dark,
      extensions: const [EchoColorExtension.graphite],
      scaffoldBackgroundColor: graphiteMainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        primary: graphiteAccent,
        secondary: graphiteAccentHover,
        surface: graphiteSurface,
        onSurfaceVariant: graphiteTextSecondary,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: graphiteTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: graphiteSidebarBg,
        foregroundColor: graphiteTextPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: graphiteTextPrimary,
        ),
      ),
      dividerColor: graphiteBorder,
      dividerTheme: const DividerThemeData(
        color: graphiteBorder,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: graphiteSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: graphiteBorder, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: graphiteBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: graphiteAccent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: GoogleFonts.inter(color: graphiteTextMuted, fontSize: 13),
        labelStyle: GoogleFonts.inter(
          color: graphiteTextSecondary,
          fontSize: 13,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: graphiteAccent,
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
          foregroundColor: graphiteAccent,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: graphiteTextPrimary,
          side: const BorderSide(color: graphiteBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      iconTheme: const IconThemeData(color: graphiteTextSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: graphiteSurface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: graphiteBorder, width: 1),
        ),
        textStyle: GoogleFonts.inter(color: graphiteTextPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: graphiteSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: graphiteBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: graphiteSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: graphiteSurface,
        contentTextStyle: GoogleFonts.inter(
          color: graphiteTextPrimary,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }
}

/// Custom theme extension for Echo-specific colors not in Material's ColorScheme.
/// To add a new theme: define a new `const EchoColorExtension(...)` and register it
/// in a new `ThemeData(extensions: [...])`.
@immutable
class EchoColorExtension extends ThemeExtension<EchoColorExtension> {
  final Color sidebarBg;
  final Color chatBg;
  final Color surfaceHover;
  final Color accentLight;
  final Color textMuted;
  final Color sentBubble;
  final Color recvBubble;

  const EchoColorExtension({
    required this.sidebarBg,
    required this.chatBg,
    required this.surfaceHover,
    required this.accentLight,
    required this.textMuted,
    required this.sentBubble,
    required this.recvBubble,
  });

  /// Dark theme colors
  static const dark = EchoColorExtension(
    sidebarBg: EchoTheme.sidebarBg,
    chatBg: EchoTheme.chatBg,
    surfaceHover: EchoTheme.surfaceHover,
    accentLight: EchoTheme.accentLight,
    textMuted: EchoTheme.textMuted,
    sentBubble: EchoTheme.sentBubble,
    recvBubble: EchoTheme.recvBubble,
  );

  /// Light theme colors
  static const light = EchoColorExtension(
    sidebarBg: EchoTheme.lightSidebarBg,
    chatBg: EchoTheme.lightChatBg,
    surfaceHover: EchoTheme.lightSurfaceHover,
    accentLight: EchoTheme.lightAccentLight,
    textMuted: EchoTheme.lightTextMuted,
    sentBubble: EchoTheme.lightSentBubble,
    recvBubble: EchoTheme.lightRecvBubble,
  );

  /// Graphite theme colors
  static const graphite = EchoColorExtension(
    sidebarBg: EchoTheme.graphiteSidebarBg,
    chatBg: EchoTheme.graphiteChatBg,
    surfaceHover: EchoTheme.graphiteSurfaceHover,
    accentLight: EchoTheme.graphiteAccentLight,
    textMuted: EchoTheme.graphiteTextMuted,
    sentBubble: EchoTheme.graphiteSentBubble,
    recvBubble: EchoTheme.graphiteRecvBubble,
  );

  @override
  EchoColorExtension copyWith({
    Color? sidebarBg,
    Color? chatBg,
    Color? surfaceHover,
    Color? accentLight,
    Color? textMuted,
    Color? sentBubble,
    Color? recvBubble,
  }) {
    return EchoColorExtension(
      sidebarBg: sidebarBg ?? this.sidebarBg,
      chatBg: chatBg ?? this.chatBg,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      accentLight: accentLight ?? this.accentLight,
      textMuted: textMuted ?? this.textMuted,
      sentBubble: sentBubble ?? this.sentBubble,
      recvBubble: recvBubble ?? this.recvBubble,
    );
  }

  @override
  EchoColorExtension lerp(EchoColorExtension? other, double t) {
    if (other is! EchoColorExtension) return this;
    return EchoColorExtension(
      sidebarBg: Color.lerp(sidebarBg, other.sidebarBg, t)!,
      chatBg: Color.lerp(chatBg, other.chatBg, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      accentLight: Color.lerp(accentLight, other.accentLight, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      sentBubble: Color.lerp(sentBubble, other.sentBubble, t)!,
      recvBubble: Color.lerp(recvBubble, other.recvBubble, t)!,
    );
  }
}

/// Theme-aware color accessors. Use `context.mainBg` instead of `EchoTheme.mainBg`.
/// Standard Material colors read from ColorScheme. Echo-specific colors read from
/// [EchoColorExtension]. Adding a new theme = define one new extension + ThemeData.
extension EchoColors on BuildContext {
  EchoColorExtension get echo =>
      Theme.of(this).extension<EchoColorExtension>()!;

  // Standard Material colors (from ThemeData / ColorScheme)
  Color get mainBg => Theme.of(this).scaffoldBackgroundColor;
  Color get surface => Theme.of(this).colorScheme.surface;
  Color get accent => Theme.of(this).colorScheme.primary;
  Color get accentHover => Theme.of(this).colorScheme.secondary;
  Color get textPrimary => Theme.of(this).colorScheme.onSurface;
  Color get textSecondary => Theme.of(this).colorScheme.onSurfaceVariant;
  Color get border => Theme.of(this).dividerColor;

  // Echo-specific colors (from ThemeExtension)
  Color get sidebarBg => echo.sidebarBg;
  Color get chatBg => echo.chatBg;
  Color get surfaceHover => echo.surfaceHover;
  Color get accentLight => echo.accentLight;
  Color get textMuted => echo.textMuted;
  Color get sentBubble => echo.sentBubble;
  Color get recvBubble => echo.recvBubble;
}
