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
