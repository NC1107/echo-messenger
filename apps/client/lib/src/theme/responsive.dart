import 'package:flutter/widgets.dart';

/// Three discrete layout tiers used across the app.
enum LayoutTier { narrow, wide, desktop }

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

  /// Hysteresis window applied around the breakpoints to prevent state loss
  /// when the user drags the window across the seam. See
  /// [StableLayoutDecision].
  static const double hysteresis = 20;

  static double width(BuildContext context) =>
      MediaQuery.of(context).size.width;

  static bool isMobile(BuildContext context) =>
      width(context) < mobileBreakpoint;

  static bool isTablet(BuildContext context) =>
      width(context) >= mobileBreakpoint && width(context) < desktopBreakpoint;

  static bool isDesktop(BuildContext context) =>
      width(context) >= desktopBreakpoint;

  /// Classifies a raw pixel width into a [LayoutTier] using the standard
  /// breakpoints — no hysteresis. Use [StableLayoutDecision.next] when you
  /// need seam stability.
  static LayoutTier layoutTier(double width) {
    if (width < mobileBreakpoint) return LayoutTier.narrow;
    if (width < desktopBreakpoint) return LayoutTier.wide;
    return LayoutTier.desktop;
  }
}

/// Picks a [LayoutTier] with a small hysteresis band so that dragging a
/// window across the 600 px or 900 px seam doesn't tear down scaffolds (which
/// would drop scroll positions, overlays, in-flight reactions, etc.).
///
/// Hold an instance in the State of any widget that switches scaffolds on
/// width — call [next] from `build`, remember the result, and only rebuild
/// the chosen scaffold when [next] returns a different tier.
class StableLayoutDecision {
  /// The currently active tier, or null until [next] is called once.
  LayoutTier? current;

  StableLayoutDecision();

  /// Resolves the tier to use given the current raw [width]. The first call
  /// returns the natural breakpoint result; subsequent calls only flip tier
  /// when [width] crosses the *outer* edge of the hysteresis window.
  LayoutTier next(double width) {
    final raw = Responsive.layoutTier(width);
    final prev = current;
    if (prev == null) {
      current = raw;
      return raw;
    }
    // Already in the desired tier — done.
    if (prev == raw) return prev;

    // Otherwise only flip if `width` has cleared the OUT edge of `prev`.
    const h = Responsive.hysteresis;
    final stayInPrev = switch (prev) {
      LayoutTier.narrow =>
        width < Responsive.mobileBreakpoint + h, // need > 620 to leave narrow
      LayoutTier.desktop =>
        width >=
            Responsive.desktopBreakpoint - h, // need < 880 to leave desktop
      LayoutTier.wide =>
        width >= Responsive.mobileBreakpoint - h &&
            width < Responsive.desktopBreakpoint + h,
    };
    if (stayInPrev) return prev;
    current = raw;
    return raw;
  }
}
