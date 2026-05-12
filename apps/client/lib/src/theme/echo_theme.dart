import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class EchoTheme {
  // shadcn-inspired dark palette
  static const mainBg = Color(0xFF0A0A0B);
  static const sidebarBg = Color(0xFF0F0F10);
  static const chatBg = Color(0xFF141415);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceHover = Color(0xFF232326);
  // Darkened from 0xFF6366F1 -> 0xFF5557E0 for WCAG AA contrast
  // (white-on-accent ~4.7:1 on this darker indigo).
  static const accent = Color(0xFF5557E0);
  static const accentHover = Color(0xFF818CF8);
  static const accentLight = Color(0x1A5557E0);
  static const textPrimary = Color(0xFFEDEDEF);
  static const textSecondary = Color(0xFFABABB0);
  static const textMuted = Color(0xFF848490);
  // Locked bubble rule: sentBubble = primary (accent), recvBubble = surface.
  static const sentBubble = accent;
  static const recvBubble = surface;
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
  // Typography helpers
  // ---------------------------------------------------------------------------

  /// Monospace style for handles, key fingerprints, code blocks, and the
  /// version line. UI text uses Inter (theme default); reach for this only
  /// when monospace is meaningful.
  static TextStyle mono({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.firaCode(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

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
    // Route any glyph not present in Inter (notably emoji codepoints) to the
    // bundled NotoEmoji font. Without this fallback, AppImage builds render
    // tofu boxes when the host system fonts are missing.
    const emojiFallback = ['NotoEmoji'];
    return baseTextTheme.copyWith(
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: primaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: primaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: primaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: primaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.47,
        color: primaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: secondaryColor,
        fontFamilyFallback: emojiFallback,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: mutedColor,
        fontFamilyFallback: emojiFallback,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: secondaryColor,
        fontFamilyFallback: emojiFallback,
      ),
    );
  }

  static FilledButtonThemeData _buildFilledButtonTheme(
    Color accentColor, {
    Color foregroundColor = Colors.white,
  }) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accentColor,
        foregroundColor: foregroundColor,
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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

  // Paper theme colors (light) — warm off-white with darkened indigo accent.
  // Replaces the legacy "Light" palette: bg warmed from #F5F5F7 -> #FAFAF7,
  // accent darkened from #5B5EE6 -> #4F46E5 for stronger WCAG AA contrast.
  static const paperAccent = Color(0xFF4F46E5);
  static const paperAccentHover = Color(0xFF6366F1);
  static const lightMainBg = Color(0xFFFAFAF7);
  static const lightSidebarBg = Color(0xFFF3F3EF);
  static const lightChatBg = Color(0xFFF8F8F5);
  static const lightSurface = Color(0xFFFFFFFC);
  static const lightSurfaceHover = Color(0xFFEEEEEA);
  static const lightTextPrimary = Color(0xFF1A1A1E);
  static const lightTextSecondary = Color(0xFF5C5C66);
  static const lightTextMuted = Color(0xFF72727E);
  // Locked bubble rule: sentBubble = primary (accent), recvBubble = surface.
  static const lightSentBubble = paperAccent;
  static const lightRecvBubble = lightSurface;
  static const lightBorder = Color(0xFFDFDFD5);
  static const lightAccentLight = Color(0x1A4F46E5);

  // Graphite theme colors (high-contrast dark with teal accent)
  // Dark onPrimary used because the high-luminance teal accent fails WCAG AA
  // against white. Near-black on teal gives ~12:1, well above 4.5:1.
  static const graphiteOnAccent = Color(0xFF0A1114);
  static const graphiteMainBg = Color(0xFF0B1114);
  static const graphiteSidebarBg = Color(0xFF101A1F);
  static const graphiteChatBg = Color(0xFF142026);
  static const graphiteSurface = Color(0xFF1A2A32);
  static const graphiteSurfaceHover = Color(0xFF22363F);
  // Darkened ~5% from 0xFF14B8A6 for stronger white-on-accent contrast.
  static const graphiteAccent = Color(0xFF13AF9D);
  static const graphiteAccentHover = Color(0xFF2DD4BF);
  static const graphiteAccentLight = Color(0x1A13AF9D);
  static const graphiteTextPrimary = Color(0xFFE7F4F8);
  static const graphiteTextSecondary = Color(0xFFA3BAC2);
  static const graphiteTextMuted = Color(0xFF8FA8B2);
  // Locked bubble rule: sentBubble = primary (accent), recvBubble = surface.
  static const graphiteSentBubble = graphiteAccent;
  static const graphiteRecvBubble = graphiteSurface;
  static const graphiteBorder = Color(0xFF2C434D);

  // Ember theme colors (warm dark with amber accent)
  // Dark onPrimary used because the high-luminance amber accent fails WCAG AA
  // against white. Near-black on amber gives ~11:1, well above 4.5:1.
  static const emberOnAccent = Color(0xFF110E0A);
  static const emberMainBg = Color(0xFF110E0A);
  static const emberSidebarBg = Color(0xFF171310);
  static const emberChatBg = Color(0xFF1C1814);
  static const emberSurface = Color(0xFF252019);
  static const emberSurfaceHover = Color(0xFF2F2920);
  // Darkened ~5% from 0xFFF59E0B for stronger white-on-accent contrast.
  static const emberAccent = Color(0xFFE9960A);
  static const emberAccentHover = Color(0xFFFBBF24);
  static const emberAccentLight = Color(0x1AE9960A);
  static const emberTextPrimary = Color(0xFFF5F0E8);
  static const emberTextSecondary = Color(0xFFA89F91);
  static const emberTextMuted = Color(0xFF91867A);
  // Locked bubble rule: sentBubble = primary (accent), recvBubble = surface.
  static const emberSentBubble = emberAccent;
  static const emberRecvBubble = emberSurface;
  static const emberBorder = Color(0xFF332D24);

  // Sakura theme colors (feminine aesthetic -- light pink with soft pastels)
  // Accent darkened from 0xFFDD1C85 -> 0xFFC0186E for WCAG AA on white text.
  // Bg warmed from 0xFFFFF5F7 -> 0xFFFFF7F5.
  static const sakuraMainBg = Color(0xFFFFF7F5);
  static const sakuraSidebarBg = Color(0xFFFFF0F3);
  static const sakuraChatBg = Color(0xFFFFF8FA);
  static const sakuraSurface = Color(0xFFFFFAFC);
  static const sakuraSurfaceHover = Color(0xFFFFE8EE);
  static const sakuraAccent = Color(0xFFC0186E);
  static const sakuraAccentHover = Color(0xFFFF45A8);
  static const sakuraAccentLight = Color(0x1AC0186E);
  static const sakuraTextPrimary = Color(0xFF2D1B2E);
  static const sakuraTextSecondary = Color(0xFF7B5A7E);
  static const sakuraTextMuted = Color(0xFF89698C);
  // Locked bubble rule: sentBubble = primary (accent), recvBubble = surface.
  static const sakuraSentBubble = sakuraAccent;
  static const sakuraRecvBubble = sakuraSurface;
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
        primary: paperAccent,
        secondary: paperAccentHover,
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
        focusBorderColor: paperAccent,
        hintColor: lightTextMuted,
        labelColor: lightTextSecondary,
      ),
      filledButtonTheme: _buildFilledButtonTheme(paperAccent),
      textButtonTheme: _buildTextButtonTheme(paperAccent),
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
        onPrimary: graphiteOnAccent,
        onSecondary: graphiteOnAccent,
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
      filledButtonTheme: _buildFilledButtonTheme(
        graphiteAccent,
        foregroundColor: graphiteOnAccent,
      ),
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
        onPrimary: emberOnAccent,
        onSecondary: emberOnAccent,
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
      filledButtonTheme: _buildFilledButtonTheme(
        emberAccent,
        foregroundColor: emberOnAccent,
      ),
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

  /// Single high-contrast theme: #7C9BFF accent on pure black with white text.
  /// Replaces the legacy `highContrastDarkTheme` + `highContrastLightTheme`
  /// split (collapsed in the 9 -> 6 palette reduction).
  static ThemeData get highContrastTheme {
    final base = darkTheme;
    const hcAccent = Color(0xFF7C9BFF);
    const hcSurface = Colors.black;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        surface: hcSurface,
        onSurface: Colors.white,
        primary: hcAccent,
        secondary: hcAccent,
        onPrimary: Colors.black,
        onSurfaceVariant: const Color(0xFFCCCCCC),
      ),
      dividerColor: Colors.white54,
      scaffoldBackgroundColor: Colors.black,
      extensions: [
        EchoColorExtension.dark.copyWith(
          sidebarBg: const Color(0xFF0A0A0A),
          chatBg: Colors.black,
          surfaceHover: const Color(0xFF1A1A1A),
          // Locked bubble rule: sent = primary, recv = surface.
          sentBubble: hcAccent,
          recvBubble: hcSurface,
          textMuted: const Color(0xFFAAAAAA),
          accentLight: const Color(0x337C9BFF),
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

  /// Surface color for grouped card rows in settings / sectioned lists.
  /// Slightly raised vs the page background so cards visually pop.
  /// Falls back to [surfaceHover] when null (see [resolvedCardRowBg]).
  final Color? cardRowBg;

  /// Optional gradient for the chat background. Null means use flat [chatBg].
  final Gradient? chatBgGradient;

  const EchoColorExtension({
    required this.sidebarBg,
    required this.chatBg,
    required this.surfaceHover,
    required this.accentLight,
    required this.textMuted,
    required this.sentBubble,
    required this.recvBubble,
    this.cardRowBg,
    this.chatBgGradient,
  });

  /// Resolved card row surface color. Defaults to [surfaceHover] when no
  /// theme-specific override was supplied.
  Color get resolvedCardRowBg => cardRowBg ?? surfaceHover;

  /// Dark theme colors
  static const dark = EchoColorExtension(
    sidebarBg: EchoTheme.sidebarBg,
    chatBg: EchoTheme.chatBg,
    surfaceHover: EchoTheme.surfaceHover,
    accentLight: EchoTheme.accentLight,
    textMuted: EchoTheme.textMuted,
    sentBubble: EchoTheme.sentBubble,
    recvBubble: EchoTheme.recvBubble,
    // Slightly brighter than surfaceHover so grouped cards stand out from
    // the page background on the new sectioned-card layouts (Settings,
    // Discover, etc.) per the v0.3 mockups.
    cardRowBg: Color(0xFF26262A),
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
    Color? cardRowBg,
    Gradient? chatBgGradient,
  }) {
    return EchoColorExtension(
      sidebarBg: sidebarBg ?? this.sidebarBg,
      chatBg: chatBg ?? this.chatBg,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      accentLight: accentLight ?? this.accentLight,
      textMuted: textMuted ?? this.textMuted,
      sentBubble: sentBubble ?? this.sentBubble,
      recvBubble: recvBubble ?? this.recvBubble,
      cardRowBg: cardRowBg ?? this.cardRowBg,
      chatBgGradient: chatBgGradient ?? this.chatBgGradient,
    );
  }

  @override
  EchoColorExtension lerp(EchoColorExtension? other, double t) {
    if (other is! EchoColorExtension) return this;
    final selfCard = cardRowBg;
    final otherCard = other.cardRowBg;
    final Color? lerpedCardRowBg;
    if (selfCard == null && otherCard == null) {
      lerpedCardRowBg = null;
    } else {
      lerpedCardRowBg = Color.lerp(
        selfCard ?? surfaceHover,
        otherCard ?? other.surfaceHover,
        t,
      );
    }
    return EchoColorExtension(
      sidebarBg: Color.lerp(sidebarBg, other.sidebarBg, t)!,
      chatBg: Color.lerp(chatBg, other.chatBg, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      accentLight: Color.lerp(accentLight, other.accentLight, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      sentBubble: Color.lerp(sentBubble, other.sentBubble, t)!,
      recvBubble: Color.lerp(recvBubble, other.recvBubble, t)!,
      cardRowBg: lerpedCardRowBg,
      chatBgGradient: t < 0.5 ? chatBgGradient : other.chatBgGradient,
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

  /// Foreground color for content rendered on top of [sentBubble].
  /// Resolves to `ColorScheme.onPrimary` because most themes keep the sent
  /// bubble at or near the accent color; promote to a dedicated
  /// [EchoColorExtension] field if a theme ever needs a non-onPrimary value.
  Color get onSentBubble => Theme.of(this).colorScheme.onPrimary;
  Color get cardRowBg => echo.resolvedCardRowBg;
  Gradient? get chatBgGradient => echo.chatBgGradient;

  // ---------------------------------------------------------------------------
  // Sidebar state hierarchy tokens (UX roadmap Phase 1).
  // Derived from existing palette so themes don't need per-theme overrides;
  // promote to ThemeExtension fields if specific themes ever need to retune.
  // ---------------------------------------------------------------------------

  /// Subtle accent-tinted background applied to a sidebar row when the
  /// conversation has unread messages. ~6% opacity keeps it readable
  /// alongside hover and selected states.
  Color get unreadRowTint => accent.withValues(alpha: 0.06);

  /// Full-saturation accent used for the 4px-wide left edge bar that marks
  /// the actively-selected conversation. Stronger signal than the existing
  /// row tint alone.
  Color get activeRowAccent => accent;

  /// Distinct color for the mention indicator badge (`@`). Reuses the
  /// shared danger/warning red so unread vs. mention badges read
  /// differently at a glance — accent for unread count, danger for
  /// "you were mentioned."
  Color get mentionBadgeBg => EchoTheme.danger;

  /// Reduced-contrast text color for muted conversations. Darker than
  /// [textMuted] so the row reads as "present but quiet" rather than
  /// "secondary." Applied to name, snippet, timestamp, and the presence
  /// dot when [Conversation.isMuted] is true.
  Color get mutedSurface => textMuted.withValues(alpha: 0.6);
}

/// Shared layout tokens for sectioned card lists (e.g. Settings).
class EchoSectionTokens {
  EchoSectionTokens._();

  /// Vertical gap between separate card groups.
  static const double groupGap = 16;

  /// Vertical gap above a [SectionHeader] label.
  static const double headerTopGap = 24;

  /// All-caps muted section label text style.
  static TextStyle sectionLabelStyle(BuildContext context) {
    return TextStyle(
      color: context.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    );
  }
}
