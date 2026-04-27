import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../theme/echo_theme.dart';
import '../avatar_utils.dart';

/// The rounded user card shown at the top of the redesigned Settings root.
/// Displays the user's avatar, display name, and `@handle`. Tapping the
/// card invokes [onTap] (intended to open the Profile detail).
class UserHeaderCard extends ConsumerWidget {
  /// Tap handler. Typically opens the Profile detail in Settings.
  final VoidCallback? onTap;

  const UserHeaderCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    final displayName = auth.username ?? 'User';
    final handle = auth.username != null ? '@${auth.username}' : '';
    final avatarUrl = resolveAvatarUrl(auth.avatarUrl, serverUrl);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: context.cardRowBg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                buildAvatar(
                  name: displayName,
                  radius: 26,
                  bgColor: context.accent,
                  imageUrl: avatarUrl,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (handle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          handle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null)
                  Icon(Icons.chevron_right, size: 18, color: context.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
