import 'package:flutter/material.dart';

/// A small circular avatar showing a person's initial on a stable, name-derived
/// HSL colour, ringed in the surface colour so it reads cleanly when faces are
/// stacked/overlapped (reply previews, thread-participant rows).
///
/// Deliberately distinct from [buildAvatar] / `UserAvatar`: those use the
/// `avatarColor` palette and load network images. This is the lightweight
/// initials-only "face" used in overlapping stacks, where the per-name HSL hue
/// plus the surface ring *is* the intended look.
class FaceCircleAvatar extends StatelessWidget {
  const FaceCircleAvatar({super.key, required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final hue = (name.hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1.0, hue, 0.55, 0.45).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
