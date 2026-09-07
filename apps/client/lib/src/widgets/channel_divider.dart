import 'package:flutter/material.dart';

/// A short vertical divider used in the channel bar.
///
/// Unifies the two dividers that had visually drifted apart: the automatic
/// text↔voice separator and the admin-inserted "divider"-kind channel. Both now
/// render identically — a thin (1px) line in the theme's divider colour — so an
/// added divider looks like the one a group spawns with.
class ChannelDivider extends StatelessWidget {
  const ChannelDivider({super.key, this.height = 24, this.width = 16});

  /// Height of the divider line.
  final double height;

  /// Total horizontal space the divider occupies (line is centred within it).
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: VerticalDivider(width: width, thickness: 1),
    );
  }
}
