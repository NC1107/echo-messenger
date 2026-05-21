/// Shared visual scaffold for the two "join group via invite" screens
/// — `JoinGroupScreen` (group-id deep link) and `TokenJoinScreen`
/// (invite-token deep link). Both screens used to copy-paste the same
/// loading skeleton, error card, avatar, action button, and back-link
/// chrome. This file extracts that chrome so each screen owns only
/// its own state + API logic and hands the rendered values to
/// [JoinPreviewScaffold].
library;

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import '../../widgets/user_avatar.dart';

/// Resolved preview data fed into [JoinPreviewScaffold]. Each screen
/// builds one of these from its API response.
class JoinPreviewData {
  final String name;
  final String? description;
  final String? iconUrl;
  final int memberCount;
  final bool isMember;

  /// Optional. `JoinGroupScreen` includes a short member preview;
  /// `TokenJoinScreen` leaves this empty.
  final List<JoinPreviewMember> members;

  const JoinPreviewData({
    required this.name,
    this.description,
    this.iconUrl,
    required this.memberCount,
    required this.isMember,
    this.members = const [],
  });
}

class JoinPreviewMember {
  final String userId;
  final String username;
  final String? avatarUrl;

  const JoinPreviewMember({
    required this.userId,
    required this.username,
    this.avatarUrl,
  });
}

class JoinPreviewScaffold extends StatelessWidget {
  final JoinPreviewData? preview;
  final bool isLoading;
  final bool isInvalid;
  final bool isJoining;
  final bool isLoggedIn;
  final String? error;
  final String serverUrl;
  final Animation<double> fadeAnimation;

  /// Title shown when the invite is expired / revoked / not found.
  final String invalidTitle;
  final String invalidBody;

  final VoidCallback onCancel;
  final VoidCallback onLogin;
  final VoidCallback onOpenGroup;
  final VoidCallback onJoin;

  const JoinPreviewScaffold({
    super.key,
    required this.preview,
    required this.isLoading,
    required this.isInvalid,
    required this.isJoining,
    required this.isLoggedIn,
    required this.error,
    required this.serverUrl,
    required this.fadeAnimation,
    required this.invalidTitle,
    required this.invalidBody,
    required this.onCancel,
    required this.onLogin,
    required this.onOpenGroup,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const _LoadingCard();
    if (isInvalid) {
      return _InvalidCard(
        fadeAnimation: fadeAnimation,
        title: invalidTitle,
        body: invalidBody,
        isLoggedIn: isLoggedIn,
        onCancel: onCancel,
      );
    }
    return _PreviewCard(
      preview: preview,
      isJoining: isJoining,
      isLoggedIn: isLoggedIn,
      error: error,
      serverUrl: serverUrl,
      fadeAnimation: fadeAnimation,
      onCancel: onCancel,
      onLogin: onLogin,
      onOpenGroup: onOpenGroup,
      onJoin: onJoin,
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SkeletonCircle(size: 80, color: context.surfaceHover),
            const SizedBox(height: 20),
            SkeletonRect(width: 160, height: 22, color: context.surfaceHover),
            const SizedBox(height: 12),
            SkeletonRect(width: 220, height: 14, color: context.surfaceHover),
            const SizedBox(height: 8),
            SkeletonRect(width: 180, height: 14, color: context.surfaceHover),
            const SizedBox(height: 20),
            SkeletonRect(width: 100, height: 13, color: context.surfaceHover),
            const SizedBox(height: 32),
            SkeletonRect(
              width: double.infinity,
              height: 48,
              color: context.surfaceHover,
              borderRadius: 10,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final JoinPreviewData? preview;
  final bool isJoining;
  final bool isLoggedIn;
  final String? error;
  final String serverUrl;
  final Animation<double> fadeAnimation;
  final VoidCallback onCancel;
  final VoidCallback onLogin;
  final VoidCallback onOpenGroup;
  final VoidCallback onJoin;

  const _PreviewCard({
    required this.preview,
    required this.isJoining,
    required this.isLoggedIn,
    required this.error,
    required this.serverUrl,
    required this.fadeAnimation,
    required this.onCancel,
    required this.onLogin,
    required this.onOpenGroup,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: fadeAnimation,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          decoration: _cardDecoration(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PreviewAvatar(preview: preview, serverUrl: serverUrl),
              const SizedBox(height: 20),
              Text(
                preview?.name ?? 'Group Invite',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if ((preview?.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  preview!.description!,
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (preview != null) ...[
                const SizedBox(height: 14),
                _MemberCountRow(memberCount: preview!.memberCount),
              ],
              if (preview != null && preview!.members.isNotEmpty) ...[
                const SizedBox(height: 18),
                _MemberStrip(members: preview!.members),
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                _ErrorChip(message: error!),
              ],
              const SizedBox(height: 28),
              _ActionButton(
                isLoggedIn: isLoggedIn,
                isMember: preview?.isMember == true,
                isJoining: isJoining,
                onLogin: onLogin,
                onOpenGroup: onOpenGroup,
                onJoin: onJoin,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: context.textSecondary,
                ),
                child: Text(
                  isLoggedIn ? 'Back to chats' : 'Cancel',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvalidCard extends StatelessWidget {
  final Animation<double> fadeAnimation;
  final String title;
  final String body;
  final bool isLoggedIn;
  final VoidCallback onCancel;

  const _InvalidCard({
    required this.fadeAnimation,
    required this.title,
    required this.body,
    required this.isLoggedIn,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: fadeAnimation,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          decoration: _cardDecoration(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: EchoTheme.danger.withValues(alpha: 0.15),
                child: const Icon(
                  Icons.link_off_rounded,
                  size: 36,
                  color: EchoTheme.danger,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onCancel,
                  style: _primaryButtonStyle(context),
                  child: Text(
                    isLoggedIn ? 'Back to chats' : 'Go to login',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
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

BoxDecoration _cardDecoration(BuildContext context) => BoxDecoration(
  color: context.surface,
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: context.border),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.15),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ],
);

ButtonStyle _primaryButtonStyle(BuildContext context) => FilledButton.styleFrom(
  backgroundColor: context.accent,
  padding: const EdgeInsets.symmetric(vertical: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
);

class _PreviewAvatar extends StatelessWidget {
  final JoinPreviewData? preview;
  final String serverUrl;
  const _PreviewAvatar({required this.preview, required this.serverUrl});

  @override
  Widget build(BuildContext context) {
    final iconUrl = preview?.iconUrl;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 40,
        backgroundColor: context.surfaceHover,
        backgroundImage: NetworkImage('$serverUrl$iconUrl'),
      );
    }
    final initials = _extractInitials(preview?.name ?? '');
    return CircleAvatar(
      radius: 40,
      backgroundColor: context.accent,
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _extractInitials(String name) {
  if (name.isEmpty) return '?';
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
  return name[0].toUpperCase();
}

class _MemberCountRow extends StatelessWidget {
  final int memberCount;
  const _MemberCountRow({required this.memberCount});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 16,
          color: context.textSecondary,
        ),
        const SizedBox(width: 6),
        Text(
          '$memberCount member${memberCount == 1 ? '' : 's'}',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
      ],
    );
  }
}

class _MemberStrip extends StatelessWidget {
  final List<JoinPreviewMember> members;
  const _MemberStrip({required this.members});

  @override
  Widget build(BuildContext context) {
    final maxShow = members.length > 5 ? 5 : members.length;
    const avatarSize = 32.0;
    const overlap = 10.0;
    final totalWidth = avatarSize + (maxShow - 1) * (avatarSize - overlap);

    return SizedBox(
      width: totalWidth,
      height: avatarSize,
      child: Stack(
        children: List.generate(maxShow, (i) {
          final member = members[i];
          return Positioned(
            left: i * (avatarSize - overlap),
            child: Container(
              width: avatarSize,
              height: avatarSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: context.surface, width: 2),
              ),
              child: UserAvatar(
                userId: member.userId,
                username: member.username,
                avatarUrl: member.avatarUrl,
                radius: (avatarSize - 4) / 2,
                openProfileOnTap: false,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ErrorChip extends StatelessWidget {
  final String message;
  const _ErrorChip({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: EchoTheme.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 16, color: EchoTheme.danger),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: EchoTheme.danger, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final bool isLoggedIn;
  final bool isMember;
  final bool isJoining;
  final VoidCallback onLogin;
  final VoidCallback onOpenGroup;
  final VoidCallback onJoin;

  const _ActionButton({
    required this.isLoggedIn,
    required this.isMember,
    required this.isJoining,
    required this.onLogin,
    required this.onOpenGroup,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn) {
      return _ButtonShell(
        onPressed: onLogin,
        icon: Icons.login_rounded,
        label: 'Log in to join',
      );
    }
    if (isMember) {
      return _ButtonShell(
        onPressed: onOpenGroup,
        icon: Icons.open_in_new_rounded,
        label: 'Open Group',
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: isJoining ? null : onJoin,
        style: _primaryButtonStyle(context),
        child: isJoining
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                'Join Group',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

class _ButtonShell extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  const _ButtonShell({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: _primaryButtonStyle(context),
      ),
    );
  }
}

class SkeletonCircle extends StatelessWidget {
  final double size;
  final Color color;
  const SkeletonCircle({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class SkeletonRect extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final double borderRadius;

  const SkeletonRect({
    super.key,
    required this.width,
    required this.height,
    required this.color,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}
