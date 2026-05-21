import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/release_notes_provider.dart';
import '../theme/echo_theme.dart';
import 'echo_bottom_sheet.dart';

/// Bottom-sheet style "What's New" modal showing the GitHub release
/// notes for the version the user just updated to.  Markdown body is
/// pre-sanitized by [sanitizeReleaseBody] so the user sees a clean
/// changelog without the auto-generated diff URLs.
///
/// Triggered once per upgrade from [home_screen]'s post-login flow via
/// [maybeShowWhatsNew].
class WhatsNewModal extends ConsumerWidget {
  final ReleaseNotesView notes;
  final bool isDialog;

  /// When provided, the "Got it" and close buttons call this instead of
  /// `Navigator.pop` — required when the modal is rendered inline by
  /// [WhatsNewInlineOverlay] (not pushed as a route), because pop would
  /// otherwise try to unwind the home screen route itself and leave the
  /// overlay stuck on screen with all input locked behind the dim layer.
  final VoidCallback? onClose;

  const WhatsNewModal({
    super.key,
    required this.notes,
    this.isDialog = false,
    this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);

    final content = _buildContent(context, theme, ref, mediaQuery);

    if (isDialog) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: context.surface,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: content,
        ),
      );
    }

    // Mobile: bottom sheet presentation.
    return Container(
      constraints: BoxConstraints(maxHeight: mediaQuery.size.height * 0.8),
      padding: EdgeInsets.only(bottom: mediaQuery.padding.bottom + 16),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: content,
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    WidgetRef ref,
    MediaQueryData mediaQuery,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isDialog) _buildDragHandle(context),
        const SizedBox(height: 16),
        _buildTitleRow(context, theme, ref),
        const SizedBox(height: 16),
        Flexible(child: _buildMarkdownBody(context, theme)),
        const SizedBox(height: 16),
        _buildDismissButton(context, ref),
      ],
    );
  }

  // Drag-handle indicator for bottom sheet.
  Widget _buildDragHandle(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: context.textMuted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTitleRow(BuildContext context, ThemeData theme, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(Icons.celebration_outlined, color: context.accent, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "What's New",
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Echo v${notes.version}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (isDialog)
            IconButton(
              icon: const Icon(Icons.close),
              color: context.textMuted,
              onPressed: () => _dismiss(context, ref),
            ),
        ],
      ),
    );
  }

  Widget _buildMarkdownBody(BuildContext context, ThemeData theme) {
    return Markdown(
      data: notes.body,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      shrinkWrap: true,
      selectable: true,
      styleSheet: _buildMarkdownStyleSheet(context, theme),
      onTapLink: (text, href, title) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
    );
  }

  MarkdownStyleSheet _buildMarkdownStyleSheet(
    BuildContext context,
    ThemeData theme,
  ) {
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      h1: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      h2: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      h3: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      listBullet: theme.textTheme.bodyMedium,
      code: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: context.surfaceHover,
      ),
      codeblockDecoration: BoxDecoration(
        color: context.surfaceHover,
        borderRadius: BorderRadius.circular(6),
      ),
      a: theme.textTheme.bodyMedium?.copyWith(
        color: context.accent,
        decoration: TextDecoration.underline,
      ),
    );
  }

  Widget _buildDismissButton(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: FilledButton(
        onPressed: () => _dismiss(context, ref),
        style: FilledButton.styleFrom(
          backgroundColor: context.accent,
          minimumSize: const Size.fromHeight(48),
        ),
        child: const Text('Got it'),
      ),
    );
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    await ref.read(releaseNotesProvider.notifier).markShown();
    if (!context.mounted) return;
    if (onClose != null) {
      onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }
}

/// Inline What's-New overlay rendered as a sibling of the page content
/// (NOT a route), so that the integrated AppTitleBar above it remains
/// draggable.  Earlier attempts used `showGeneralDialog` with a
/// transparent barrier — but Flutter's [ModalRoute] always inserts a
/// pointer-absorbing barrier across the full screen regardless of color,
/// which left users unable to drag the window when the "Got it" button
/// landed off-screen.
class WhatsNewInlineOverlay extends ConsumerWidget {
  final ReleaseNotesView notes;
  final VoidCallback onDismiss;

  const WhatsNewInlineOverlay({
    super.key,
    required this.notes,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        // Dim layer covers only the body area; the AppTitleBar above this
        // overlay continues to receive pointer events.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await ref.read(releaseNotesProvider.notifier).markShown();
              onDismiss();
            },
            child: Container(color: Colors.black54),
          ),
        ),
        Center(
          child: GestureDetector(
            // Absorb taps on the card itself so they don't fall through to
            // the dim layer above.
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            // The modal's own button handlers call markShown(); this
            // callback only needs to clear the overlay state. Calling
            // markShown twice doesn't corrupt anything (idempotent
            // SharedPreferences write), but signals broken ownership.
            child: WhatsNewModal(
              notes: notes,
              isDialog: true,
              onClose: onDismiss,
            ),
          ),
        ),
      ],
    );
  }
}

/// Convenience wrapper called by `home_screen` once after login.  Shows
/// the modal if-and-only-if [releaseNotesProvider] has populated
/// [ReleaseNotesView] data.  On mobile uses a bottom sheet; on desktop
/// signals back to the caller via [onShow] so the caller can render
/// [WhatsNewInlineOverlay] inline below its title bar.
Future<void> maybeShowWhatsNew(
  BuildContext context,
  WidgetRef ref, {
  void Function(ReleaseNotesView)? onShow,
}) async {
  final view = ref.read(releaseNotesProvider).value;
  if (view == null) return;
  if (!context.mounted) return;
  final isDesktop = MediaQuery.sizeOf(context).width >= 600;
  if (isDesktop) {
    // Hand the notes back to the caller — home_screen renders an inline
    // overlay so the title bar stays draggable.
    onShow?.call(view);
  } else {
    await showEchoBottomSheet<void>(
      context,
      builder: (_) => WhatsNewModal(notes: view),
    );
  }
}
