/// Launch-time account picker.
///
/// Shown after the splash when `tryAutoLogin` fails AND the device has at
/// least one persisted account in [AccountsStorage]. Replaces the bare
/// "go straight to Login" fallback with a Discord/Slack-style "Welcome back"
/// screen so the user can tap-to-resume a stored session without re-entering
/// credentials.
///
/// The Settings → Account → "Switch account" entry continues to open the
/// bottom-sheet variant (`AccountSwitcherSheet`); the picker here is a
/// separate full-screen route consumed only by the splash flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/accounts_storage.dart';
import '../../theme/echo_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/account_list_row.dart';
import '../../widgets/echo_logo_icon.dart';
import '../../widgets/loading_indicator.dart';

const String _kRouteLogin = '/login';
const String _kRouteHome = '/home';
const String _kTitleWelcomeBack = 'Welcome back';
const String _kAddAccountLabel = 'Add another account';
const String _kSignOutLabel = 'Not your account? Sign out';
const String _kSwitchFailedMessage =
    "Couldn't refresh session — please sign in again";

/// Full-screen route shown by the splash flow when stored accounts exist but
/// the user is not logged in.
class AccountPickerScreen extends ConsumerStatefulWidget {
  const AccountPickerScreen({super.key});

  @override
  ConsumerState<AccountPickerScreen> createState() =>
      _AccountPickerScreenState();
}

class _AccountPickerScreenState extends ConsumerState<AccountPickerScreen> {
  late Future<AccountsSnapshot> _snapshotFuture;

  /// Stable identifier of the row currently mid-switch. While set, every row's
  /// tap handler is disabled and the matching row shows a spinner in place of
  /// its trailing slot. Cleared on failure so the user can retry.
  String? _busyAccountId;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = ref.read(authProvider.notifier).listAccounts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(
        child: FutureBuilder<AccountsSnapshot>(
          future: _snapshotFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const CenteredLoadingIndicator();
            }
            final data =
                snapshot.data ??
                const AccountsSnapshot(accounts: [], activeAccountId: null);
            return _buildBody(data);
          },
        ),
      ),
    );
  }

  Widget _buildBody(AccountsSnapshot snap) {
    final accounts = [...snap.accounts]
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _BrandHeader(),
                  const SizedBox(height: 24),
                  _buildAccountList(accounts),
                  const SizedBox(height: 4),
                  Divider(height: 1, color: context.border),
                  _AddAccountRow(
                    onTap: _busyAccountId == null ? _onTapAddAccount : null,
                  ),
                  const SizedBox(height: 16),
                  _SignOutFooter(
                    onTap: _busyAccountId == null ? _onTapSignOut : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAccountList(List<StoredAccount> accounts) {
    if (accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No saved accounts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final account in accounts)
          AccountListRow(
            account: account,
            isActive: false,
            subtitle: _subtitleFor(account),
            onTap: _busyAccountId == null ? () => _onTapAccount(account) : null,
            trailing: _trailingFor(account),
          ),
      ],
    );
  }

  Widget? _trailingFor(StoredAccount account) {
    if (_busyAccountId != account.id) return null;
    return const InlineLoadingSpinner(size: 20);
  }

  String _subtitleFor(StoredAccount account) {
    final host = accountRowHostLabel(account.serverUrl);
    final lastUsed = _formatLastUsed(account.lastUsed);
    if (lastUsed == null) return host;
    return '$host  ·  Last used $lastUsed';
  }

  Future<void> _onTapAccount(StoredAccount account) async {
    setState(() => _busyAccountId = account.id);

    // Tear down per-user state before swapping identities. Mirrors the home
    // screen's _logout sequence so a half-initialised provider doesn't leak
    // across the identity boundary.
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    await ref.read(cryptoProvider.notifier).resetState();

    final ok = await ref
        .read(authProvider.notifier)
        .switchToAccount(account.id);
    if (!mounted) return;

    if (ok) {
      context.go(_kRouteHome);
      return;
    }

    setState(() => _busyAccountId = null);
    _showSwitchFailedSnackbar();
    // Send the user to the login screen so they can re-enter credentials.
    // The login screen's existing knownServers pre-fill picks up the
    // matching username when the server URL matches.
    context.go(_kRouteLogin);
  }

  void _onTapAddAccount() {
    context.go(_kRouteLogin);
  }

  Future<void> _onTapSignOut() async {
    final auth = ref.read(authProvider.notifier);
    await auth.accountsStorage.clear();
    if (!mounted) return;
    context.go(_kRouteLogin);
  }

  void _showSwitchFailedSnackbar() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text(_kSwitchFailedMessage)),
    );
  }

  /// Compact "5m" / "3h" / "2d" / "Jan 14" descriptor. Returns null when the
  /// stored stamp is the zero epoch (i.e. the row was added before the
  /// `lastUsed` field shipped).
  String? _formatLastUsed(DateTime when) {
    if (when.millisecondsSinceEpoch <= 0) return null;
    return formatRelativeTimeShort(when, older: formatShortDate);
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EchoLogoIcon(size: 64),
        const SizedBox(height: 16),
        Text(
          'Echo',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _kTitleWelcomeBack,
          style: TextStyle(fontSize: 14, color: context.textSecondary),
        ),
      ],
    );
  }
}

class _AddAccountRow extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddAccountRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _kAddAccountLabel,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: context.cardRowBg,
                child: Icon(Icons.add, size: 20, color: context.textPrimary),
              ),
              const SizedBox(width: 14),
              Text(
                _kAddAccountLabel,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: context.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignOutFooter extends StatelessWidget {
  final VoidCallback? onTap;

  const _SignOutFooter({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _kSignOutLabel,
      button: true,
      child: Center(
        child: TextButton(
          onPressed: onTap,
          child: Text(
            _kSignOutLabel,
            style: TextStyle(
              fontSize: 13,
              color: context.textMuted,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }
}
