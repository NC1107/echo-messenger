import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/participated_threads_provider.dart';
import '../theme/echo_theme.dart';

/// Persistent "Threads" entry that sits at the very top of the sidebar
/// conversation list (#449). Shows a count badge when at least one
/// participated thread has unread replies.
///
/// The widget triggers an initial fetch on first mount so the badge math
/// is correct without waiting for the user to open the threads screen.
class ThreadsSidebarEntry extends ConsumerStatefulWidget {
  final VoidCallback? onTap;

  const ThreadsSidebarEntry({super.key, this.onTap});

  @override
  ConsumerState<ThreadsSidebarEntry> createState() =>
      _ThreadsSidebarEntryState();
}

class _ThreadsSidebarEntryState extends ConsumerState<ThreadsSidebarEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Cheap: provider short-circuits when already loading; load fills
      // the badge so users see the unread count without navigating.
      ref.read(participatedThreadsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = ref.watch(
      participatedThreadsProvider.select((s) => s.unreadThreadCount),
    );
    return Semantics(
      label: unreadCount > 0 ? 'Threads, $unreadCount unread' : 'Threads',
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 18,
                color: context.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Threads',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
              if (unreadCount > 0)
                Container(
                  key: const ValueKey('threads-sidebar-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$unreadCount',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
