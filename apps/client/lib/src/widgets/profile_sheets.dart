import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/group_info_screen.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import 'echo_bottom_sheet.dart';

/// Opens the user profile in a bottom sheet on mobile or a dialog on desktop.
///
/// On screens >= 900 px wide a centred [Dialog] (400 x 500) is shown.
/// On narrower screens an [showEchoBottomSheet] is opened with a drag
/// handle, capped at ~85 % of the viewport height so chat context stays
/// visible above it.
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
    showEchoBottomSheet<void>(
      context,
      dragHandle: true,
      builder: (_) =>
          _ProfileSheetBody(child: UserProfileScreen(userId: userId)),
    );
  }
}

/// Opens the group info panel in a bottom sheet on mobile or a dialog on desktop.
///
/// On screens >= 900 px wide a wide [Dialog] (680 x 600) is shown.
/// On narrower screens an [showEchoBottomSheet] is opened with a drag
/// handle.
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
    showEchoBottomSheet<void>(
      context,
      dragHandle: true,
      builder: (_) => _ProfileSheetBody(
        child: GroupInfoScreen(conversationId: conversationId),
      ),
    );
  }
}

/// Inner body for the profile/group-info sheet — caps at 85 % of the
/// viewport so chat context stays peeking out above the sheet and
/// pushes the bottom edge up when the soft keyboard opens.
class _ProfileSheetBody extends StatelessWidget {
  const _ProfileSheetBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final screenHeight = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
        child: child,
      ),
    );
  }
}
