/// One avatar, one tap behaviour, one place to render the presence dot.
///
/// Before this widget, the same `Stack(avatar, Positioned(dot))` pattern
/// was inlined in `members_panel.dart`, `group_members_sheet.dart`,
/// `message_item.dart` and a handful of other surfaces — each version
/// drifted slightly (dot size, border colour, tap target, what tapping
/// actually does). `UserAvatar` collapses those copies into one widget:
///
///   • Always resolves `avatarUrl` against `serverUrlProvider`.
///   • Tapping the avatar opens [UserProfileScreen] by default — set
///     `openProfileOnTap: false` to opt out, or pass `onTap` to override.
///   • `showPresence: true` overlays a coloured status dot driven by
///     `websocketProvider`. Dot colour comes from the same
///     [presenceStatusDotColor] helper conversation rows already use, so
///     the colour stays consistent across every surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/server_url_provider.dart';
import '../providers/user_presence_provider.dart';
import '../screens/user_profile_screen.dart';
import '../theme/echo_theme.dart';
import '../utils/presence.dart';
import 'avatar_utils.dart' show buildAvatar, resolveAvatarUrl;

class UserAvatar extends ConsumerWidget {
  /// The user this avatar represents. Used to (a) resolve the tap → open
  /// profile and (b) look up the presence status when [showPresence] is on.
  final String userId;

  /// Display name. Drives the initial-letter fallback and the screen-
  /// reader label.
  final String username;

  /// Optional relative or absolute avatar path. Relative paths are
  /// resolved against the current `serverUrlProvider`.
  final String? avatarUrl;

  /// Half-size of the avatar circle. Default 16 matches the in-chat
  /// sender avatar; member panels typically use 18–20.
  final double radius;

  /// Overlay a coloured presence dot. Off by default — most surfaces in
  /// chat hide the dot, member listings turn it on.
  final bool showPresence;

  /// Whether tapping opens [UserProfileScreen]. Default true. Pass false
  /// for read-only contexts (mention picker hover thumbnails, etc.).
  final bool openProfileOnTap;

  /// Override the default tap. When non-null this fully replaces the
  /// "open profile" behaviour. Use sparingly — the whole point of this
  /// widget is to make taps consistent.
  final VoidCallback? onTap;

  /// Optional long-press handler. Surfaces that want a context menu
  /// (right-click on desktop, long-press on mobile) wire this.
  final VoidCallback? onLongPress;

  /// Override the fallback background colour. Defaults to the
  /// per-username colour from `avatarColor(name)`.
  final Color? bgColor;

  /// Override the initial-letter fallback (e.g. show a group icon).
  final Widget? fallbackIcon;

  const UserAvatar({
    super.key,
    required this.userId,
    required this.username,
    this.avatarUrl,
    this.radius = 16,
    this.showPresence = false,
    this.openProfileOnTap = true,
    this.onTap,
    this.onLongPress,
    this.bgColor,
    this.fallbackIcon,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.watch(serverUrlProvider);
    final resolvedUrl = resolveAvatarUrl(avatarUrl, serverUrl);

    Widget avatar = buildAvatar(
      name: username,
      radius: radius,
      imageUrl: resolvedUrl,
      bgColor: bgColor,
      fallbackIcon: fallbackIcon,
    );

    if (showPresence) {
      final presence = ref.watch(userPresenceProvider(userId));
      final dotSize = (radius * 0.55).clamp(8.0, 14.0).toDouble();
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: presenceColor(
                  presence.status,
                  isOnline: presence.isOnline,
                ),
                shape: BoxShape.circle,
                border: Border.all(color: EchoTheme.sidebarBg, width: 1.5),
              ),
            ),
          ),
        ],
      );
    }

    final effectiveTap =
        onTap ?? (openProfileOnTap ? () => _openProfile(context, ref) : null);

    if (effectiveTap == null && onLongPress == null) return avatar;

    return Semantics(
      container: true,
      label: 'open $username profile',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: effectiveTap,
        onLongPress: onLongPress,
        child: avatar,
      ),
    );
  }

  void _openProfile(BuildContext context, WidgetRef ref) {
    UserProfileScreen.show(context, ref, userId);
  }
}
