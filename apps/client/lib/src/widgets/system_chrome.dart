import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps [child] in an [AnnotatedRegion] that aligns the Android status bar
/// and navigation bar icons with the active theme.
///
/// Without this, the system status bar inherits OS defaults — on a light
/// device with our indigo brand surfaces this can render dark icons on a
/// dark sidebar (or vice versa). The icon brightness is the inverse of the
/// theme brightness: a dark theme needs light icons, a light theme needs
/// dark icons. The status bar itself stays transparent so the underlying
/// scaffold colour shows through.
class EchoSystemChrome extends StatelessWidget {
  final Widget child;

  const EchoSystemChrome({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;
    final navBarColor = theme.scaffoldBackgroundColor;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        statusBarBrightness: theme.brightness,
        systemNavigationBarColor: navBarColor,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      child: child,
    );
  }
}
