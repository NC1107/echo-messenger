import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// A single row in the mobile attachment bottom sheet.
class AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const AttachOption({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: context.textSecondary),
      title: Text(label, style: TextStyle(color: context.textPrimary)),
      onTap: onTap,
    );
  }
}
