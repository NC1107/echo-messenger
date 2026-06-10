import 'package:flutter/material.dart';

/// Full-area centered loading spinner — the canonical "this surface is loading"
/// placeholder.
///
/// Replaces ~a dozen hand-written `Center(child: CircularProgressIndicator())`
/// copies so the app's loading look has a single home: restyle once here (size,
/// stroke, a branded spinner) and every loading surface follows. Defaults match
/// the previous bare indicator exactly, so adopting it is a no-op visually.
class CenteredLoadingIndicator extends StatelessWidget {
  /// Optional override for the indicator colour; null uses the theme default.
  final Color? color;

  const CenteredLoadingIndicator({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Center(child: CircularProgressIndicator(color: color));
  }
}

/// Small fixed-size spinner for inline contexts — inside a button, a chip, a
/// list tile. Replaces the hand-written
/// `SizedBox(width: N, height: N, child: CircularProgressIndicator(strokeWidth: 2))`
/// idiom so every inline spinner shares one stroke + sizing convention and can
/// be restyled in one place. [size] is the square edge; pass [color] on a
/// coloured surface (e.g. white on an accent button).
class InlineLoadingSpinner extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const InlineLoadingSpinner({
    super.key,
    this.size = 20,
    this.strokeWidth = 2,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: strokeWidth, color: color),
    );
  }
}
