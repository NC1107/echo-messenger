import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/admin_realtime_provider.dart';
import '../../providers/admin_stats_provider.dart';
import '../../services/toast_service.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton_loader.dart';

/// Operator dashboard for issue #682. Renders the headline metrics from
/// `GET /api/admin/stats` in a responsive grid and the latest open feedback
/// rows from `GET /api/admin/feedback` underneath.
///
/// The provider gates on the server's `AdminUser` extractor, so a non-admin
/// caller falls through to the error branch (HTTP 403). Route-level gating
/// on `auth.isAdmin` will be wired separately — see the report in the PR
/// body. Until then, the screen is reachable but useless to non-admins.
class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(adminDashboardProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: async.when(
        loading: () => const _DashboardLoadingSkeleton(),
        error: (err, _) => _ErrorView(
          message: err.toString(),
          onRetry: () => ref.read(adminDashboardProvider.notifier).refresh(),
        ),
        data: (data) => _DashboardBody(data: data),
      ),
    );
  }
}

/// Loading state for the whole dashboard — same skeleton card grid the
/// realtime section uses, plus a stub of the "Last 24h" aggregate grid so
/// the layout doesn't jump when data arrives.
class _DashboardLoadingSkeleton extends StatelessWidget {
  const _DashboardLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Realtime', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const StatCardGridSkeleton(),
        const SizedBox(height: 24),
        Text('Last 24h', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const StatCardGridSkeleton(count: 6),
      ],
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final AdminDashboardData data;
  const _DashboardBody({required this.data});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        // The Notifier exposes a refresh that flips into loading; the
        // pull-to-refresh affordance just defers to it.
        final element = ProviderScope.containerOf(context, listen: false);
        await element.read(adminDashboardProvider.notifier).refresh();
        await element.read(adminRealtimeProvider.notifier).refresh();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Realtime', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const _RealtimeSection(),
          const SizedBox(height: 24),
          Text('Last 24h', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _StatsGrid(stats: data.stats),
          const SizedBox(height: 24),
          Text(
            'Recent feedback',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (data.feedback.isEmpty)
            const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No open feedback',
              body:
                  'When users submit feedback through Settings → About, it '
                  'will appear here.',
            )
          else
            ...data.feedback.map(_FeedbackTile.new),
        ],
      ),
    );
  }
}

/// Renders the four headline cards from [adminRealtimeProvider] plus the
/// friendly 403 / reauth_required surfaces.
///
/// Pulled out of [_DashboardBody] so the realtime panel can fail
/// independently of the 24h aggregate panel — the operator should still
/// see historical numbers if the realtime endpoint hiccups, and vice versa.
class _RealtimeSection extends ConsumerStatefulWidget {
  const _RealtimeSection();

  @override
  ConsumerState<_RealtimeSection> createState() => _RealtimeSectionState();
}

class _RealtimeSectionState extends ConsumerState<_RealtimeSection> {
  bool _toastShown = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminRealtimeProvider);

    // Surface the reauth-required signal exactly once per error transition;
    // re-firing the toast on every poll tick is just noise.
    ref.listen<AsyncValue<AdminRealtimeStats>>(adminRealtimeProvider, (
      prev,
      next,
    ) {
      final err = next.error;
      if (err is AdminReauthRequired && !_toastShown) {
        _toastShown = true;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Re-enter your password to access the admin dashboard.',
            ),
          ),
        );
      } else if (err is! AdminReauthRequired) {
        _toastShown = false;
      }
    });

    return async.when(
      loading: () => const StatCardGridSkeleton(),
      error: (err, _) => _RealtimeError(err),
      data: (data) => _RealtimeGrid(stats: data),
    );
  }
}

class _RealtimeError extends StatelessWidget {
  final Object err;
  const _RealtimeError(this.err);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, message) = _resolveCopy(err);
    return Card(
      key: const Key('admin-realtime-error'),
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: scheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  static (IconData, String) _resolveCopy(Object err) {
    if (err is AdminForbidden) {
      return (Icons.lock_outline, "You're not an admin on this server.");
    }
    if (err is AdminReauthRequired) {
      return (
        Icons.password_outlined,
        'Re-enter your password to view realtime stats.',
      );
    }
    return (Icons.error_outline, 'Could not load realtime stats: $err');
  }
}

class _RealtimeGrid extends StatelessWidget {
  final AdminRealtimeStats stats;
  const _RealtimeGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final messagesPerSec = stats.messagesPerSec;
    // Render 2 decimal places when the rate is <10 msg/s (most servers most
    // of the time); above that, integer precision is enough.
    final messagesLabel = messagesPerSec >= 10
        ? messagesPerSec.toStringAsFixed(0)
        : messagesPerSec.toStringAsFixed(2);

    final cards = <Widget>[
      _StatCard(
        key: const Key('admin-realtime-card-sessions'),
        label: 'Connected sessions',
        value: stats.connectedSessions,
      ),
      _StatCardText(
        key: const Key('admin-realtime-card-mps'),
        label: 'Messages / sec',
        value: messagesLabel,
      ),
      _StatCard(
        key: const Key('admin-realtime-card-voice'),
        label: 'Voice rooms',
        value: stats.activeVoiceRooms,
      ),
      _StatCardText(
        key: const Key('admin-realtime-card-db'),
        label: 'DB pool',
        value: '${stats.dbPoolInFlight} / ${stats.dbPoolMax}',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = width >= 720 ? 4 : (width >= 480 ? 2 : 1);
        const spacing = 12.0;
        final cardWidth = (width - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards) SizedBox(width: cardWidth, child: card),
          ],
        );
      },
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final AdminStats stats;
  const _StatsGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    // Card list — we use a wrap rather than GridView so cards size to their
    // content on narrow screens and pack 2–3 per row on wider layouts
    // without needing manual breakpoints.
    final cards = <Widget>[
      _StatCard(label: 'Users (total)', value: stats.usersTotal),
      _StatCard(label: 'Active 24h', value: stats.usersActive24h),
      _StatCard(label: 'Messages 24h', value: stats.messages24h),
      _StatCard(label: 'Groups (total)', value: stats.groupsTotal),
      _StatCard(label: 'Online devices', value: stats.onlineDevices),
      _StatCard(label: 'Feedback open', value: stats.feedbackOpen),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Target ~180px per card, clamp to 2-4 columns.
        final width = constraints.maxWidth;
        final colsIfSmall = width >= 480 ? 3 : 2;
        final cols = width >= 720 ? 4 : colsIfSmall;
        const spacing = 12.0;
        final cardWidth = (width - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards) SizedBox(width: cardWidth, child: card),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  const _StatCard({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    // Don't forward `key` into the inner widget — the outer element already
    // owns the key. Passing it again would surface two widgets with the
    // same key in the tree and break `find.byKey` in tests.
    return _StatCardText(label: label, value: '$value');
  }
}

/// Variant of [_StatCard] that takes a pre-formatted string value — used
/// for the realtime cards that need a decimal (messages/sec) or a
/// composite ("3 / 32") rendering.
class _StatCardText extends StatelessWidget {
  final String label;
  final String value;
  const _StatCardText({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackTile extends ConsumerWidget {
  final FeedbackItem item;
  const _FeedbackTile(this.item);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final who = (item.username?.isNotEmpty ?? false)
        ? item.username!
        : item.userId;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    who,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _formatTimestamp(item.createdAt),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Delete feedback',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () => _confirmDelete(context, ref),
                  icon: Icon(
                    Icons.delete_outline,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (item.title.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              item.body,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirm, then hard-delete this report. Optimistic removal lives in the
  /// notifier; we only surface a toast on failure so the operator knows the
  /// row is still there.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Delete feedback?',
      content:
          'This permanently removes the report. This action cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;

    try {
      await ref.read(adminDashboardProvider.notifier).deleteFeedback(item.id);
    } catch (e) {
      if (context.mounted) {
        ToastService.show(
          context,
          'Failed to delete feedback',
          type: ToastType.error,
        );
      }
    }
  }

  /// Render the row's `created_at` as a short UTC string. We intentionally
  /// avoid the `intl` locale-formatter dance here; the dashboard is an
  /// operator surface and ISO-ish output is the most useful.
  String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: 'Could not load admin data',
      body: message,
      ctaLabel: 'Retry',
      onCta: onRetry,
      variant: EmptyStateVariant.error,
    );
  }
}
