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
  static const textMuted = Color(0xFF9090A0);
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

  // ---------------------------------------------------------------------------
  // Shared factory methods for theme construction
  // ---------------------------------------------------------------------------

  static TextTheme _buildTextTheme({
    required Brightness brightness,
    required Color primaryColor,
    required Color secondaryColor,
    required Color mutedColor,
  }) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    final baseTextTheme = GoogleFonts.interTextTheme(base);
    return baseTextTheme.copyWith(
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: primaryColor,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: primaryColor,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: primaryColor,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: primaryColor,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.47,
        color: primaryColor,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: secondaryColor,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: mutedColor,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: secondaryColor,
      ),
    );
  }

  static FilledButtonThemeData _buildFilledButtonTheme(Color accentColor) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accentColor,
        foregroundColor: Colors.white,
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  static TextButtonThemeData _buildTextButtonTheme(Color accentColor) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentColor,
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    );
  }

  static OutlinedButtonThemeData _buildOutlinedButtonTheme(
    Color foregroundColor,
    Color borderColor,
  ) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: foregroundColor,
        side: BorderSide(color: borderColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  static InputDecorationTheme _buildInputTheme({
    required Color fillColor,
    required Color borderColor,
    required Color focusBorderColor,
    required Color hintColor,
    required Color labelColor,
  }) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: focusBorderColor, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: GoogleFonts.inter(color: hintColor, fontSize: 13),
      labelStyle: GoogleFonts.inter(color: labelColor, fontSize: 13),
    );
  }

  // ---------------------------------------------------------------------------
  // Dark theme
  // ---------------------------------------------------------------------------

  static ThemeData get darkTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.dark,
      primaryColor: textPrimary,
      secondaryColor: textSecondary,
      mutedColor: textMuted,
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
      inputDecorationTheme: _buildInputTheme(
        fillColor: surface,
        borderColor: border,
        focusBorderColor: accent,
        hintColor: textMuted,
        labelColor: textSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(accent),
      textButtonTheme: _buildTextButtonTheme(accent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(textPrimary, border),
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

  // Light theme colors — tuned to avoid harsh pure white
  static const lightMainBg = Color(0xFFF5F5F7);
  static const lightSidebarBg = Color(0xFFF0F0F3);
  static const lightChatBg = Color(0xFFF8F8FA);
  static const lightSurface = Color(0xFFFAFAFC);
  static const lightSurfaceHover = Color(0xFFEEEEF1);
  static const lightTextPrimary = Color(0xFF1A1A1E);
  static const lightTextSecondary = Color(0xFF5C5C66);
  static const lightTextMuted = Color(0xFF9494A0);
  static const lightSentBubble = Color(0xFF5B5EE6);
  static const lightRecvBubble = Color(0xFFE8E8EC);
  static const lightBorder = Color(0xFFDFDFE5);
  static const lightAccentLight = Color(0x1A5B5EE6);

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

  // Ember theme colors (warm dark with amber accent)
  static const emberMainBg = Color(0xFF110E0A);
  static const emberSidebarBg = Color(0xFF171310);
  static const emberChatBg = Color(0xFF1C1814);
  static const emberSurface = Color(0xFF252019);
  static const emberSurfaceHover = Color(0xFF2F2920);
  static const emberAccent = Color(0xFFF59E0B);
  static const emberAccentHover = Color(0xFFFBBF24);
  static const emberAccentLight = Color(0x1AF59E0B);
  static const emberTextPrimary = Color(0xFFF5F0E8);
  static const emberTextSecondary = Color(0xFFA89F91);
  static const emberTextMuted = Color(0xFF736A5E);
  static const emberSentBubble = Color(0xFFB45309);
  static const emberRecvBubble = Color(0xFF252019);
  static const emberBorder = Color(0xFF332D24);

  // Neon theme colors (gamer aesthetic -- dark with electric green/cyan accents)
  static const neonMainBg = Color(0xFF0A0A0F);
  static const neonSidebarBg = Color(0xFF0D0D14);
  static const neonChatBg = Color(0xFF0E0E16);
  static const neonSurface = Color(0xFF14141E);
  static const neonSurfaceHover = Color(0xFF1A1A28);
  static const neonAccent = Color(0xFF00FF88);
  static const neonAccentHover = Color(0xFF33FFaa);
  static const neonAccentLight = Color(0x1A00FF88);
  static const neonTextPrimary = Color(0xFFE0E0E8);
  static const neonTextSecondary = Color(0xFF8888A0);
  static const neonTextMuted = Color(0xFF555570);
  static const neonSentBubble = Color(0xFF00CC6A);
  static const neonRecvBubble = Color(0xFF1A1A28);
  static const neonBorder = Color(0xFF222235);

  // Sakura theme colors (feminine aesthetic -- light pink with soft pastels)
  static const sakuraMainBg = Color(0xFFFFF5F7);
  static const sakuraSidebarBg = Color(0xFFFFF0F3);
  static const sakuraChatBg = Color(0xFFFFF8FA);
  static const sakuraSurface = Color(0xFFFFFAFC);
  static const sakuraSurfaceHover = Color(0xFFFFE8EE);
  static const sakuraAccent = Color(0xFFE91E8C);
  static const sakuraAccentHover = Color(0xFFFF45A8);
  static const sakuraAccentLight = Color(0x1AE91E8C);
  static const sakuraTextPrimary = Color(0xFF2D1B2E);
  static const sakuraTextSecondary = Color(0xFF7B5A7E);
  static const sakuraTextMuted = Color(0xFFB898BB);
  static const sakuraSentBubble = Color(0xFFE91E8C);
  static const sakuraRecvBubble = Color(0xFFFFE8EE);
  static const sakuraBorder = Color(0xFFF0D4DC);

  // ---------------------------------------------------------------------------
  // Light theme
  // ---------------------------------------------------------------------------

  static ThemeData get lightTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.light,
      primaryColor: lightTextPrimary,
      secondaryColor: lightTextSecondary,
      mutedColor: lightTextMuted,
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
      inputDecorationTheme: _buildInputTheme(
        fillColor: lightSurface,
        borderColor: lightBorder,
        focusBorderColor: accent,
        hintColor: lightTextMuted,
        labelColor: lightTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(accent),
      textButtonTheme: _buildTextButtonTheme(accent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(
        lightTextPrimary,
        lightBorder,
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

  // ---------------------------------------------------------------------------
  // Graphite theme
  // ---------------------------------------------------------------------------

  static ThemeData get graphiteTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.dark,
      primaryColor: graphiteTextPrimary,
      secondaryColor: graphiteTextSecondary,
      mutedColor: graphiteTextMuted,
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
      inputDecorationTheme: _buildInputTheme(
        fillColor: graphiteSurface,
        borderColor: graphiteBorder,
        focusBorderColor: graphiteAccent,
        hintColor: graphiteTextMuted,
        labelColor: graphiteTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(graphiteAccent),
      textButtonTheme: _buildTextButtonTheme(graphiteAccent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(
        graphiteTextPrimary,
        graphiteBorder,
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

  // ---------------------------------------------------------------------------
  // Ember theme
  // ---------------------------------------------------------------------------

  static ThemeData get emberTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.dark,
      primaryColor: emberTextPrimary,
      secondaryColor: emberTextSecondary,
      mutedColor: emberTextMuted,
    );

    return ThemeData(
      brightness: Brightness.dark,
      extensions: const [EchoColorExtension.ember],
      scaffoldBackgroundColor: emberMainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        primary: emberAccent,
        secondary: emberAccentHover,
        surface: emberSurface,
        onSurfaceVariant: emberTextSecondary,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: emberTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: emberSidebarBg,
        foregroundColor: emberTextPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: emberTextPrimary,
        ),
      ),
      dividerColor: emberBorder,
      dividerTheme: const DividerThemeData(
        color: emberBorder,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: _buildInputTheme(
        fillColor: emberSurface,
        borderColor: emberBorder,
        focusBorderColor: emberAccent,
        hintColor: emberTextMuted,
        labelColor: emberTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(emberAccent),
      textButtonTheme: _buildTextButtonTheme(emberAccent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(
        emberTextPrimary,
        emberBorder,
      ),
      iconTheme: const IconThemeData(color: emberTextSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: emberSurface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: emberBorder, width: 1),
        ),
        textStyle: GoogleFonts.inter(color: emberTextPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: emberSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: emberBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: emberSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: emberSurface,
        contentTextStyle: GoogleFonts.inter(
          color: emberTextPrimary,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Neon theme
  // ---------------------------------------------------------------------------

  static ThemeData get neonTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.dark,
      primaryColor: neonTextPrimary,
      secondaryColor: neonTextSecondary,
      mutedColor: neonTextMuted,
    );

    return ThemeData(
      brightness: Brightness.dark,
      extensions: const [EchoColorExtension.neon],
      scaffoldBackgroundColor: neonMainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        primary: neonAccent,
        secondary: neonAccentHover,
        surface: neonSurface,
        onSurfaceVariant: neonTextSecondary,
        error: danger,
        onPrimary: Color(0xFF0A0A0F),
        onSecondary: Color(0xFF0A0A0F),
        onSurface: neonTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: neonSidebarBg,
        foregroundColor: neonTextPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: neonTextPrimary,
        ),
      ),
      dividerColor: neonBorder,
      dividerTheme: const DividerThemeData(
        color: neonBorder,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: _buildInputTheme(
        fillColor: neonSurface,
        borderColor: neonBorder,
        focusBorderColor: neonAccent,
        hintColor: neonTextMuted,
        labelColor: neonTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(neonAccent),
      textButtonTheme: _buildTextButtonTheme(neonAccent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(
        neonTextPrimary,
        neonBorder,
      ),
      iconTheme: const IconThemeData(color: neonTextSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: neonSurface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: neonBorder, width: 1),
        ),
        textStyle: GoogleFonts.inter(color: neonTextPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: neonSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: neonBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: neonSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: neonSurface,
        contentTextStyle: GoogleFonts.inter(
          color: neonTextPrimary,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sakura theme
  // ---------------------------------------------------------------------------

  static ThemeData get sakuraTheme {
    final textTheme = _buildTextTheme(
      brightness: Brightness.light,
      primaryColor: sakuraTextPrimary,
      secondaryColor: sakuraTextSecondary,
      mutedColor: sakuraTextMuted,
    );

    return ThemeData(
      brightness: Brightness.light,
      extensions: const [EchoColorExtension.sakura],
      scaffoldBackgroundColor: sakuraMainBg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.light(
        primary: sakuraAccent,
        secondary: sakuraAccentHover,
        surface: sakuraSurface,
        onSurfaceVariant: sakuraTextSecondary,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: sakuraTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: sakuraSidebarBg,
        foregroundColor: sakuraTextPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: sakuraTextPrimary,
        ),
      ),
      dividerColor: sakuraBorder,
      dividerTheme: const DividerThemeData(
        color: sakuraBorder,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: _buildInputTheme(
        fillColor: sakuraSurface,
        borderColor: sakuraBorder,
        focusBorderColor: sakuraAccent,
        hintColor: sakuraTextMuted,
        labelColor: sakuraTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(sakuraAccent),
      textButtonTheme: _buildTextButtonTheme(sakuraAccent),
      outlinedButtonTheme: _buildOutlinedButtonTheme(
        sakuraTextPrimary,
        sakuraBorder,
      ),
      iconTheme: const IconThemeData(color: sakuraTextSecondary, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: sakuraSurface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: sakuraBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: GoogleFonts.inter(color: sakuraTextPrimary, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: sakuraSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: sakuraBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: sakuraSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: sakuraSurface,
        contentTextStyle: GoogleFonts.inter(
          color: sakuraTextPrimary,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // High-contrast themes
  // ---------------------------------------------------------------------------

  static ThemeData get highContrastDarkTheme {
    final base = darkTheme;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.black,
        onSurface: Colors.white,
        primary: Colors.yellow,
        secondary: const Color(0xFFFFFF66),
        onSurfaceVariant: const Color(0xFFCCCCCC),
      ),
      dividerColor: Colors.white54,
      scaffoldBackgroundColor: Colors.black,
      extensions: [
        EchoColorExtension.dark.copyWith(
          sidebarBg: const Color(0xFF0A0A0A),
          chatBg: Colors.black,
          surfaceHover: const Color(0xFF1A1A1A),
          sentBubble: const Color(0xFF444400),
          recvBubble: const Color(0xFF1A1A1A),
          textMuted: const Color(0xFFAAAAAA),
          accentLight: const Color(0x33FFFF00),
        ),
      ],
    );
  }

  static ThemeData get highContrastLightTheme {
    final base = lightTheme;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.white,
        onSurface: Colors.black,
        primary: const Color(0xFF0000CC),
        secondary: const Color(0xFF0000AA),
        onSurfaceVariant: const Color(0xFF333333),
      ),
      dividerColor: Colors.black54,
      scaffoldBackgroundColor: Colors.white,
      extensions: [
        EchoColorExtension.light.copyWith(
          sidebarBg: const Color(0xFFF0F0F0),
          chatBg: Colors.white,
          surfaceHover: const Color(0xFFE8E8E8),
          sentBubble: const Color(0xFF0000CC),
          recvBubble: const Color(0xFFE8E8E8),
          textMuted: const Color(0xFF555555),
          accentLight: const Color(0x220000CC),
        ),
      ],
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

  /// Ember theme colors
  static const ember = EchoColorExtension(
    sidebarBg: EchoTheme.emberSidebarBg,
    chatBg: EchoTheme.emberChatBg,
    surfaceHover: EchoTheme.emberSurfaceHover,
    accentLight: EchoTheme.emberAccentLight,
    textMuted: EchoTheme.emberTextMuted,
    sentBubble: EchoTheme.emberSentBubble,
    recvBubble: EchoTheme.emberRecvBubble,
  );

  /// Neon theme colors
  static const neon = EchoColorExtension(
    sidebarBg: EchoTheme.neonSidebarBg,
    chatBg: EchoTheme.neonChatBg,
    surfaceHover: EchoTheme.neonSurfaceHover,
    accentLight: EchoTheme.neonAccentLight,
    textMuted: EchoTheme.neonTextMuted,
    sentBubble: EchoTheme.neonSentBubble,
    recvBubble: EchoTheme.neonRecvBubble,
  );

  /// Sakura theme colors
  static const sakura = EchoColorExtension(
    sidebarBg: EchoTheme.sakuraSidebarBg,
    chatBg: EchoTheme.sakuraChatBg,
    surfaceHover: EchoTheme.sakuraSurfaceHover,
    accentLight: EchoTheme.sakuraAccentLight,
    textMuted: EchoTheme.sakuraTextMuted,
    sentBubble: EchoTheme.sakuraSentBubble,
    recvBubble: EchoTheme.sakuraRecvBubble,
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
