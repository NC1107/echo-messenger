import 'package:flutter/widgets.dart';

/// Centralized responsive breakpoints for consistent layout behavior.
///
/// Use these instead of ad-hoc `MediaQuery.of(context).size.width < 600`
/// checks scattered across the codebase.
class Responsive {
  Responsive._();

  /// Screens narrower than this are considered mobile/phone layout.
  static const double mobileBreakpoint = 600;

  /// Screens at or wider than this get the full desktop layout.
  static const double desktopBreakpoint = 900;

  static double width(BuildContext context) =>
      MediaQuery.of(context).size.width;

  static bool isMobile(BuildContext context) =>
      width(context) < mobileBreakpoint;

  static bool isTablet(BuildContext context) =>
      width(context) >= mobileBreakpoint && width(context) < desktopBreakpoint;

  static bool isDesktop(BuildContext context) =>
      width(context) >= desktopBreakpoint;
}
