import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/featured_group_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart';
import 'echo_bottom_sheet.dart';

/// One-shot "Join the community" offer shown on a user's first visit to the
/// home screen. Presents the server's configured welcome group with a single
/// Join CTA and a dismiss. Caller is responsible for the "only once" gate
/// (a SharedPreferences flag); this widget just renders + joins.
Future<void> showWelcomeGroupSheet(BuildContext context, FeaturedGroup group) {
  return showEchoBottomSheet<void>(
    context,
    dragHandle: true,
    builder: (_) => _WelcomeGroupBody(group: group),
  );
}

class _WelcomeGroupBody extends ConsumerStatefulWidget {
  final FeaturedGroup group;
  const _WelcomeGroupBody({required this.group});

  @override
  ConsumerState<_WelcomeGroupBody> createState() => _WelcomeGroupBodyState();
}

class _WelcomeGroupBodyState extends ConsumerState<_WelcomeGroupBody> {
  bool _joining = false;

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    try {
      final res = await http
          .post(
            Uri.parse('$serverUrl/api/groups/${widget.group.id}/join'),
            headers: {
              'Authorization': 'Bearer ${token ?? ''}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      // 200/201 = joined; 400 with AlreadyMember is fine too — either way the
      // group ends up in their list after a reload.
      final ok =
          res.statusCode == 200 ||
          res.statusCode == 201 ||
          res.body.contains('AlreadyMember');
      if (ok) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (!mounted) return;
        Navigator.of(context).pop();
        ToastService.show(
          context,
          'Joined ${widget.group.title}',
          type: ToastType.success,
        );
      } else {
        setState(() => _joining = false);
        ToastService.show(
          context,
          'Could not join the group',
          type: ToastType.error,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _joining = false);
      ToastService.show(
        context,
        'Could not join the group',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final hasDescription = group.description?.isNotEmpty ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Welcome to Echo',
            style: TextStyle(
              color: context.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              buildAvatar(
                imageUrl: resolveAvatarUrl(
                  group.iconUrl,
                  ref.read(serverUrlProvider),
                ),
                name: group.title,
                radius: 28,
                bgColor: groupAvatarColor(group.title),
                fallbackIcon: const Icon(
                  Icons.group,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${group.memberCount} '
                      'member${group.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            hasDescription
                ? group.description!
                : 'Say hello and meet other people on Echo. You can always '
                      'leave later.',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _joining ? null : _join,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: _joining
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Join group'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _joining ? null : () => Navigator.of(context).pop(),
            child: Text(
              'Maybe later',
              style: TextStyle(color: context.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
