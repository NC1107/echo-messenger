import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/group_info_screen.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';

/// Opens the user profile in a bottom sheet on mobile or a dialog on desktop.
///
/// On screens >= 900 px wide a centred [Dialog] (400 x 500) is shown.
/// On narrower screens a drag-down-dismissible [ModalBottomSheet] covers
/// ~85 % of the viewport height so chat context remains visible above it.
void showUserProfileSheet(BuildContext context, WidgetRef ref, String userId) {
  final width = MediaQuery.of(context).size.width;
  if (width >= 900) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: 400,
          height: 500,
          child: UserProfileScreen(userId: userId),
        ),
      ),
    );
  } else {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) =>
          _ProfileSheet(child: UserProfileScreen(userId: userId)),
    );
  }
}

/// Opens the group info panel in a bottom sheet on mobile or a dialog on desktop.
///
/// On screens >= 900 px wide a wide [Dialog] (680 x 600) is shown.
/// On narrower screens a drag-down-dismissible [ModalBottomSheet] is used.
void showGroupProfileSheet(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) {
  final width = MediaQuery.of(context).size.width;
  if (width >= 900) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: 680,
          height: 600,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GroupInfoScreen(conversationId: conversationId),
          ),
        ),
      ),
    );
  } else {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) =>
          _ProfileSheet(child: GroupInfoScreen(conversationId: conversationId)),
    );
  }
}

/// Shared bottom-sheet container: rounded top corners, drag handle, and
/// an 85 %-viewport height constraint so the sheet feels intentional.
class _ProfileSheet extends StatelessWidget {
  const _ProfileSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final screenHeight = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
