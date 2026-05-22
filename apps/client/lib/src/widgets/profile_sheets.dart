import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/group_info_screen.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import 'echo_bottom_sheet.dart';

/// Opens the user profile in a bottom sheet on mobile or a dialog on desktop.
///
/// On screens >= 700 px wide a centred [Dialog] is shown, sized to fit the
/// viewport (clamped to 360-480 wide, 400-600 tall, ≤90 % of viewport height).
/// On narrower screens an [showEchoBottomSheet] is opened with a drag
/// handle, capped at ~85 % of the viewport height so chat context stays
/// visible above it.
void showUserProfileSheet(BuildContext context, WidgetRef ref, String userId) {
  final mq = MediaQuery.of(context).size;
  if (mq.width >= 700) {
    final dialogWidth = mq.width.clamp(360.0, 480.0);
    final dialogHeight = (mq.height * 0.9).clamp(400.0, 600.0);
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
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
/// On screens >= 800 px wide a wide [Dialog] is shown, sized to fit the
/// viewport (clamped to 480-760 wide, 480-720 tall, ≤90 % of viewport height).
/// On narrower screens an [showEchoBottomSheet] is opened with a drag handle.
void showGroupProfileSheet(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) {
  final mq = MediaQuery.of(context).size;
  if (mq.width >= 800) {
    final dialogWidth = mq.width.clamp(480.0, 760.0);
    final dialogHeight = (mq.height * 0.9).clamp(480.0, 720.0);
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
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
