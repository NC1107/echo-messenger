import 'package:flutter/material.dart';

class EchoLogoIcon extends StatelessWidget {
  final double size;

  const EchoLogoIcon({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final assetPath = isDark
        ? 'assets/images/echo_logo_white.png'
        : 'assets/images/echo_logo_black.png';

    return Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}
