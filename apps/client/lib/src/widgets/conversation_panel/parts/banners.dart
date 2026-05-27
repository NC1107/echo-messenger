part of '../../conversation_panel.dart';

/// Banner builders surfaced above the conversation list:
///  * pending-contacts banner
///  * "session replaced on another device" reconnect prompt
///  * sidebar update banner (downloading / ready-to-install / installing /
///    error / available variants)
///  * the "Report a bug" affordance shown when no update banner is visible.
mixin _ConversationPanelBannersMixin on ConsumerState<ConversationPanel> {
  /// True after the user manually dismisses the "session replaced" banner.
  /// Resets on next reconnect (the websocket clears `wasReplaced`, and we
  /// re-show the banner if a future replacement happens).
  bool _replacedBannerDismissed = false;

  Widget _buildPendingBanner(int pendingCount) {
    return GestureDetector(
      onTap: widget.onShowContacts,
      child: EchoBanner(
        icon: Icons.person_add,
        severity: EchoBannerSeverity.info,
        message:
            '$pendingCount pending contact ${pendingCount == 1 ? 'request' : 'requests'}',
        margin: const EdgeInsets.symmetric(
          horizontal: EchoSpacing.lg,
          vertical: EchoSpacing.xs,
        ),
        borderRadius: BorderRadius.circular(EchoRadii.md),
        showBorder: true,
        action: Icon(
          Icons.chevron_right,
          size: 16,
          color: context.textSecondary,
        ),
      ),
    );
  }

  // Hand-rolled (not EchoBanner): needs two tap zones — surface reconnects, close button must not bubble.
  Widget _buildReplacedBanner(BuildContext context, bool wsReplaced) {
    if (!wsReplaced || _replacedBannerDismissed) return const SizedBox.shrink();
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            // Trigger a fresh connect, clearing wasReplaced if applicable
            final ws = ref.read(websocketProvider.notifier);
            if (ref.read(websocketProvider).wasReplaced) {
              ws.reconnectAfterReplacement();
            } else {
              ws.connect();
            }
          },
          child: Container(
            height: 56,
            margin: const EdgeInsets.symmetric(horizontal: EchoSpacing.lg),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: EchoTheme.warning, width: 1),
            ),
            padding: const EdgeInsets.only(
              left: EchoSpacing.md,
              right: EchoSpacing.xs,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.devices_other,
                  size: 18,
                  color: EchoTheme.warning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Signed in on another device. Tap to reconnect.',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Icon(Icons.refresh, size: 18, color: EchoTheme.warning),
                Semantics(
                  label: 'Dismiss session banner',
                  button: true,
                  child: IconButton(
                    icon: Icon(Icons.close, size: 16, color: context.textMuted),
                    tooltip: 'Dismiss',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    // Stop the parent GestureDetector from also firing a
                    // reconnect when the user just wants to close the banner.
                    onPressed: () {
                      setState(() => _replacedBannerDismissed = true);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  /// Resolves the visible label, optional action button, dismiss flag, and
  /// optional progress bar for the current update state.
  ({String label, Widget? action, bool showDismiss, Widget? progress})
  _resolveUpdateBannerState(BuildContext context, UpdateState update) {
    switch (update.status) {
      case UpdateStatus.downloading:
        final pct = (update.downloadProgress * 100).toInt();
        return (
          label: 'Downloading update... $pct%',
          // Cancel removed — users were aborting downloads halfway, leaving
          // half-fetched payloads on disk that the next launch had to clean
          // up. Updates are quick; no in-flight cancel surface.
          action: null,
          showDismiss: false,
          progress: LinearProgressIndicator(
            value: update.downloadProgress,
            color: context.accent,
            backgroundColor: context.border,
            minHeight: 2,
          ),
        );
      case UpdateStatus.readyToInstall:
        return (
          label: 'v${update.latestVersion} ready',
          action: TextButton(
            onPressed: () => ref.read(updateProvider.notifier).applyUpdate(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Restart',
              style: TextStyle(
                color: context.accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          showDismiss: true,
          progress: null,
        );
      case UpdateStatus.installing:
        return (
          label: 'Installing update...',
          action: const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          showDismiss: false,
          progress: null,
        );
      case UpdateStatus.error:
        return (
          label: 'Update failed',
          action: TextButton(
            onPressed: () => ref.read(updateProvider.notifier).downloadUpdate(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Retry',
              style: TextStyle(color: context.accent, fontSize: 11),
            ),
          ),
          showDismiss: true,
          progress: null,
        );
      default: // idle, update available
        return _resolveAvailableUpdateState(context, update);
    }
  }

  /// Resolves banner state for the idle / update-available case.
  ({String label, Widget? action, bool showDismiss, Widget? progress})
  _resolveAvailableUpdateState(BuildContext context, UpdateState update) {
    if (kIsWeb) {
      // Web bundle stale: --pwa-strategy=none means no SW auto-refresh; non-dismissible banner forces hard-refresh (#1175).
      return (
        label:
            'New version v${update.latestVersion} available — '
            'hard-refresh to update (Ctrl+Shift+R / Cmd+Shift+R)',
        action: null,
        showDismiss: false,
        progress: null,
      );
    }
    return (
      label: 'v${update.latestVersion} available',
      action: TextButton(
        onPressed: update.assetDownloadUrl != null
            ? () => ref.read(updateProvider.notifier).downloadUpdate()
            : () {
                final url = update.downloadUrl;
                if (url != null) launchUrl(Uri.parse(url));
              },
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          update.assetDownloadUrl != null ? 'Update' : 'Download',
          style: TextStyle(
            color: context.accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      showDismiss: true,
      progress: null,
    );
  }

  Widget _buildSidebarUpdateBanner(BuildContext context) {
    final update = ref.watch(updateProvider);

    const activeStatuses = {
      UpdateStatus.downloading,
      UpdateStatus.readyToInstall,
      UpdateStatus.installing,
    };
    final isActive = activeStatuses.contains(update.status);
    final isVisible =
        update.updateAvailable ||
        isActive ||
        update.status == UpdateStatus.error;
    // Fall back to bug-report when no update banner.
    if (!isVisible) return _buildBugReportRow(context);
    if (update.dismissed && !isActive) return _buildBugReportRow(context);

    final (:label, :action, :showDismiss, :progress) =
        _resolveUpdateBannerState(context, update);

    return Container(
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_outlined,
                  size: 14,
                  color: context.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ?action,
                if (showDismiss)
                  IconButton(
                    icon: Icon(Icons.close, size: 12, color: context.textMuted),
                    onPressed: () =>
                        ref.read(updateProvider.notifier).dismiss(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
              ],
            ),
          ),
          ?progress,
        ],
      ),
    );
  }

  /// Small "Report a bug" affordance shown in the slot the update banner
  /// otherwise occupies. Visible only when no update is in flight — keeps
  /// the sidebar tight when an update is pending / installing.
  Widget _buildBugReportRow(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: 'report a bug',
          button: true,
          child: TextButton.icon(
            icon: const Icon(Icons.bug_report_outlined, size: 14),
            label: const Text('Report a bug'),
            onPressed: () => showFeedbackDialog(context),
            style: TextButton.styleFrom(
              foregroundColor: context.textMuted,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ),
    );
  }
}
