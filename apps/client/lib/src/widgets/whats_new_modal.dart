import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/release_notes_provider.dart';
import '../theme/echo_theme.dart';

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

  const WhatsNewModal({super.key, required this.notes, this.isDialog = false});

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
        if (!isDialog) ...[
          // Drag-handle indicator for bottom sheet.
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
        const SizedBox(height: 16),

        // Title row.
        Padding(
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
                  onPressed: () async {
                    await ref.read(releaseNotesProvider.notifier).markShown();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Scrollable markdown body.
        Flexible(
          child: Markdown(
            data: notes.body,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            shrinkWrap: true,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              h1: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              h2: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              h3: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
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
            ),
            onTapLink: (text, href, title) {
              if (href != null) {
                launchUrl(
                  Uri.parse(href),
                  mode: LaunchMode.externalApplication,
                );
              }
            },
          ),
        ),
        const SizedBox(height: 16),

        // Dismiss button.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: FilledButton(
            onPressed: () async {
              await ref.read(releaseNotesProvider.notifier).markShown();
              if (context.mounted) Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: context.accent,
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Got it'),
          ),
        ),
      ],
    );
  }
}

/// Height of the integrated [AppTitleBar] in `window_chrome.dart` — kept in
/// sync so the dialog barrier leaves the title-bar drag region uncovered.
const double _kTitleBarHeight = 36;

/// Convenience wrapper called by `home_screen` once after login.  Shows
/// the modal if-and-only-if [releaseNotesProvider] has populated
/// [ReleaseNotesView] data (i.e. the user updated since they last saw
/// notes AND we have a non-empty body to render).
Future<void> maybeShowWhatsNew(BuildContext context, WidgetRef ref) async {
  final view = ref.read(releaseNotesProvider).value;
  if (view == null) return;
  if (!context.mounted) return;
  final isDesktop = MediaQuery.sizeOf(context).width >= 600;
  if (isDesktop) {
    // showGeneralDialog with a transparent system barrier + our own dim
    // overlay positioned BELOW the title bar. Otherwise the dialog blocks
    // the window-drag region and a user whose "Got it" button is offscreen
    // can't move the window to reach it.
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: "What's New",
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      pageBuilder: (ctx, _, _) {
        return Stack(
          children: [
            // Manual dim layer that leaves the top title-bar strip clickable.
            Positioned(
              left: 0,
              right: 0,
              top: _kTitleBarHeight,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await ref.read(releaseNotesProvider.notifier).markShown();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: Container(color: Colors.black54),
              ),
            ),
            // Center the actual modal inside the body region.
            Positioned(
              left: 0,
              right: 0,
              top: _kTitleBarHeight,
              bottom: 0,
              child: Center(child: WhatsNewModal(notes: view, isDialog: true)),
            ),
          ],
        );
      },
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WhatsNewModal(notes: view),
    );
  }
}
