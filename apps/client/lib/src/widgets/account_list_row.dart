/// Shared visual primitive for the account-switcher surfaces.
///
/// One row = avatar + username + (server-host | optional subtitle) + optional
/// trailing widget (check mark on the bottom-sheet's active row; spinner on the
/// launch picker's in-flight row).
///
/// Two callers consume it today:
///   * `AccountSwitcherSheet` — bottom sheet entry from Settings.
///   * `AccountPickerScreen` — launch-time fallback when auto-login fails and
///     stored accounts exist.
///
/// Centralising the row visuals here means a future tweak (e.g. swapping the
/// host text for a server-name pill, or adding a presence dot to the avatar)
/// lands on both surfaces in one edit instead of drifting between two
/// hand-rolled copies.
library;

import 'package:flutter/material.dart';

import '../services/accounts_storage.dart';
import '../theme/echo_theme.dart';
import 'user_avatar.dart';

/// Strip the scheme + path off [url] so the row's secondary line shows a
/// compact "host.example.com" instead of the full origin. Falls back to the
/// raw string when the URL fails to parse.
String accountRowHostLabel(String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return url;
  return host;
}

/// Single row in either the account-switcher sheet or the launch-time picker.
class AccountListRow extends StatelessWidget {
  /// Account being rendered.
  final StoredAccount account;

  /// When true, render a check icon on the trailing edge. Mutually exclusive
  /// with [trailing] (check wins so the active-row marker can't be overridden
  /// by accident).
  final bool isActive;

  /// Optional second line under the username. Defaults to the account's
  /// server host. Pass an empty string to suppress the subtitle line entirely
  /// (rare — most callers want a non-empty descriptor).
  final String? subtitle;

  /// Tap handler. Null disables the row's ink ripple (used while a switch is
  /// in flight to prevent double-taps).
  final VoidCallback? onTap;

  /// Custom trailing widget for the row (e.g. a small CircularProgressIndicator
  /// during a switch). Ignored when [isActive] is true.
  final Widget? trailing;

  /// Accessibility label override. Defaults to a sensible "switch to X" /
  /// "account X active" label derived from [account] + [isActive].
  final String? semanticLabel;

  const AccountListRow({
    super.key,
    required this.account,
    required this.isActive,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final label =
        semanticLabel ??
        (isActive
            ? 'account ${account.username} active'
            : 'switch to ${account.username}');
    final secondary = subtitle ?? accountRowHostLabel(account.serverUrl);
    return Semantics(
      label: label,
      button: onTap != null,
      selected: isActive,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              UserAvatar(
                userId: account.userId,
                username: account.username,
                avatarUrl: account.avatarUrl,
                radius: 20,
                openProfileOnTap: false,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.username,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (secondary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        secondary,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              _buildTrailing(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrailing(BuildContext context) {
    if (isActive) {
      return Icon(Icons.check_circle, size: 20, color: context.accent);
    }
    return trailing ?? const SizedBox.shrink();
  }
}
