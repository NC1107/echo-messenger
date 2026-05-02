import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import '../../theme/responsive.dart';

/// Round "+" button that opens the attachment menu.
///
/// On mobile, tapping opens the bottom-sheet attach menu via
/// [onShowMobileMenu]. On desktop, it directly invokes [onPickFile].
class AttachFileButton extends StatelessWidget {
  final VoidCallback onPickFile;
  final VoidCallback onShowMobileMenu;

  const AttachFileButton({
    super.key,
    required this.onPickFile,
    required this.onShowMobileMenu,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final onTap = isMobile ? onShowMobileMenu : onPickFile;
    return Tooltip(
      message: isMobile ? 'Attach' : 'Attach file',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.surface,
              shape: BoxShape.circle,
              border: Border.all(color: context.border, width: 1),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.add, size: 20, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}
