/// Centralised right-click / long-press context menu, Discord-style,
/// themed to Echo's design system.
///
/// PR 1 of 4 — foundation only. No existing call sites are migrated;
/// the testbed at `/dev/context-menu` is the only consumer.
///
/// Usage from a call site:
///
/// ```dart
/// GestureDetector(
///   onSecondaryTapDown: (d) => EchoContextMenu.open(
///     context: context,
///     ref: ref,
///     target: MessageTarget(/* ... */),
///     anchor: d.globalPosition,
///   ),
///   onLongPressStart: (d) => EchoContextMenu.open(
///     context: context,
///     ref: ref,
///     target: MessageTarget(/* ... */),
///     anchor: d.globalPosition,
///   ),
///   child: child,
/// );
/// ```
///
/// The [open] entry point picks the desktop overlay or the mobile
/// bottom-sheet layout based on viewport short side, both rendered from
/// the same [ContextMenuModel] tree so action wiring lives in one place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'context_menu_overlay.dart';
import 'context_menu_sheet.dart';

/// One row inside a context menu. The icon renders right-aligned to
/// match the Discord screenshot the design is anchored to.
///
/// `submenu` is mutually exclusive with `onTap` — a row either fires
/// an action or slides the overlay into a nested section stack. The
/// overlay enforces this at draw time by hiding the chevron when
/// `onTap` is non-null.
class ContextMenuAction {
  const ContextMenuAction({
    required this.label,
    required this.icon,
    this.onTap,
    this.submenu,
    this.isDanger = false,
    this.shortcut,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  /// When non-null, tapping this row replaces the visible menu with
  /// `submenu` (rendered as a "Back ← Title" header + nested sections).
  /// Used for "Add Reaction →" full picker and "Apps →" entry points.
  final List<ContextMenuSection>? submenu;

  /// Tints label + icon with [EchoTheme.danger]. Apply to destructive
  /// rows (Delete, Kick, Ban, Report).
  final bool isDanger;

  /// Optional keyboard hint shown as muted mono text right of the
  /// label (e.g. `⌘C`). Purely decorative in PR 1 — actual keyboard
  /// dispatch is deferred to a follow-up.
  final String? shortcut;
}

/// A divider-separated group of rows. The overlay paints a 1px
/// `context.border` line between consecutive sections and skips it
/// for the first section.
class ContextMenuSection {
  const ContextMenuSection({required this.actions});
  final List<ContextMenuAction> actions;
}

/// Optional header rendered above all sections. PR 1 ships only the
/// "inline reactions row" variant (the four-emoji strip in the
/// Discord screenshot); future variants (message preview, member
/// avatar header) plug in here without touching the layout widgets.
sealed class ContextMenuHeader {
  const ContextMenuHeader();
}

/// Four-emoji recent-reactions strip + "Add Reaction →" chevron.
/// The emojis come from the bundled NotoColorEmoji set; in PR 2 we
/// pull them from `emoji_picker_flutter`'s recent-tab storage so the
/// list reflects the user's actual usage instead of a static curation.
class InlineReactionsHeader extends ContextMenuHeader {
  const InlineReactionsHeader({
    required this.emojis,
    required this.onPick,
    required this.onOpenFullPicker,
  });

  final List<String> emojis;
  final void Function(String emoji) onPick;
  final VoidCallback onOpenFullPicker;
}

/// Resolved menu tree for one target. Built from a target by the
/// per-target registries (see `actions/*_actions_registry.dart`,
/// added in PRs 2-4).
class ContextMenuModel {
  const ContextMenuModel({this.header, required this.sections, this.title});

  /// Optional Discord-style header (inline reactions, etc.).
  final ContextMenuHeader? header;

  /// Action sections, painted top-to-bottom with dividers between.
  final List<ContextMenuSection> sections;

  /// Optional short title shown above the sections — used by submenus
  /// for the "← Back" affordance ("Add Reaction"). Null on the root
  /// menu (the inline-reactions header acts as the implicit title).
  final String? title;
}

/// Tagged target classes. Each PR 2-4 introduces one concrete target
/// + its registry. They are sealed here so the registry switch is
/// exhaustive at compile time.
sealed class ContextMenuTarget {
  const ContextMenuTarget();

  /// Short, stable identifier used for telemetry and debug logging.
  String get analyticsName;
}

/// Placeholder target type for the PR-1 testbed. PRs 2-4 add
/// MessageTarget / ConversationTarget / MemberTarget alongside this
/// and migrate real call sites.
class DebugTarget extends ContextMenuTarget {
  const DebugTarget(this.label);
  final String label;
  @override
  String get analyticsName => 'debug:$label';
}

/// Single public entry point. Picks desktop overlay vs mobile bottom
/// sheet based on viewport short side; the breakpoint matches the
/// rest of the app (see chat_panel responsive logic).
class EchoContextMenu {
  EchoContextMenu._();

  /// Mobile threshold in logical pixels. Below this we render the
  /// bottom-sheet variant; at or above we render the anchored
  /// overlay. Matches the existing app-wide tablet breakpoint.
  static const double _mobileBreakpoint = 600;

  static Future<void> open({
    required BuildContext context,
    required WidgetRef ref,
    required ContextMenuTarget target,
    required Offset anchor,
    required ContextMenuModel model,
  }) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    if (shortest < _mobileBreakpoint) {
      return showContextMenuSheet(context: context, model: model);
    }
    return showContextMenuOverlay(
      context: context,
      anchor: anchor,
      model: model,
    );
  }
}
