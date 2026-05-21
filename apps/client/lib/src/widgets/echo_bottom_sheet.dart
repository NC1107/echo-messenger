/// Single entry point for every modal bottom sheet in the app.
///
/// Every `showModalBottomSheet` site used to pass the same `isScrollControlled:
/// true`, `backgroundColor: …`, and a `shape:` (or had its child wrap itself
/// in `ClipRRect`) with the same 16-px top corner radius. Drift had already
/// started — two callers used Material's `shape:` param, the rest passed
/// `Colors.transparent` and rounded the child themselves. Same pixels, two
/// ways to get there.
///
/// `showEchoBottomSheet` bakes in:
///   • `backgroundColor: context.surface`
///   • `shape:` rounded top corners (16 px)
///   • `isScrollControlled: true` + `useSafeArea: true` defaults
///   • optional drag handle pill prepended to the body
///
/// Callers just supply a builder for the content. Result: changing the
/// surface colour, corner radius, or drag-handle styling is a single edit
/// here, not a 13-file sweep.
library;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Show an Echo-styled modal bottom sheet.
///
/// [dragHandle] prepends a centred 36×4 pill above the body — used by the
/// mobile profile sheet and the group-members sheet. Defaults to off; most
/// sheets are short-lived menus that don't need it.
Future<T?> showEchoBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dragHandle = false,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    backgroundColor: context.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final body = builder(ctx);
      if (!dragHandle) return body;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(),
          Flexible(child: body),
        ],
      );
    },
  );
}

/// Centred 36×4 pill used as a drag handle at the top of Echo bottom
/// sheets. Exposed for surfaces that build a sheet manually
/// (`DraggableScrollableSheet`-based ones) and want the same visual.
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: context.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
