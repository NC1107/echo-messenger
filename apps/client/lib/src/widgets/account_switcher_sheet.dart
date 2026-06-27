/// Discord/Slack-style account switcher.
///
/// One row per persisted account (`avatar + username + server origin` with
/// a check mark on the active one) plus an "Add another account" row at
/// the bottom. Tapping a row mints a fresh access token against the
/// account's persisted refresh token (or HttpOnly cookie on web) via
/// [AuthNotifier.switchToAccount]; on success the parent routes back to
/// the home screen, on failure we surface a "Session expired" snackbar
/// and bounce the user to the login screen with the username pre-filled.
///
/// Built on [showEchoBottomSheet] so the surface, shape, and drag-handle
/// rules stay consistent with the rest of the app's sheets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';
import '../router/routes.dart';
import '../services/accounts_storage.dart';
import '../theme/echo_theme.dart';
import 'account_list_row.dart';
import 'echo_bottom_sheet.dart';
import 'loading_indicator.dart';

const String _kSwitchAccountTitle = 'Switch account';
const String _kAddAccountLabel = 'Add another account';
const String _kSessionExpired = 'Session expired — please sign in again.';

/// Open the account-switcher bottom sheet. Resolves once the sheet is
/// dismissed (either by tapping a row or by swiping away).
Future<void> showAccountSwitcherSheet(BuildContext context) {
  return showEchoBottomSheet<void>(
    context,
    dragHandle: true,
    builder: (_) => const AccountSwitcherSheet(),
  );
}

/// Sheet body. Exposed as a widget (not just a function) so tests can
/// pump it directly inside a `ProviderScope`.
class AccountSwitcherSheet extends ConsumerStatefulWidget {
  const AccountSwitcherSheet({super.key});

  @override
  ConsumerState<AccountSwitcherSheet> createState() =>
      _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends ConsumerState<AccountSwitcherSheet> {
  late Future<AccountsSnapshot> _snapshotFuture;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = ref.read(authProvider.notifier).listAccounts();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: FutureBuilder<AccountsSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _buildLoading();
          }
          final data =
              snapshot.data ??
              const AccountsSnapshot(accounts: [], activeAccountId: null);
          return _buildBody(data);
        },
      ),
    );
  }

  Widget _buildLoading() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: CenteredLoadingIndicator(),
    );
  }

  Widget _buildBody(AccountsSnapshot snap) {
    final accounts = [...snap.accounts]
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            _kSwitchAccountTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
        ),
        for (final account in accounts)
          AccountListRow(
            account: account,
            isActive: account.id == snap.activeAccountId,
            onTap: _switching ? null : () => _onTapAccount(account),
          ),
        Divider(height: 1, color: context.border),
        _AddAccountRow(onTap: _switching ? null : _onTapAddAccount),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _onTapAccount(StoredAccount account) async {
    if (account.id == ref.read(authProvider).userId.toString()) {
      // Already active — just dismiss.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _switching = true);

    // Tear down per-user state before swapping identities. Matches the
    // sequence the home screen's _logout uses.
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    await ref.read(cryptoProvider.notifier).resetState();

    final ok = await ref
        .read(authProvider.notifier)
        .switchToAccount(account.id);

    if (!mounted) return;
    Navigator.of(context).maybePop();

    if (ok) {
      context.go(routeHome);
      return;
    }
    _showExpiredSnackbar();
    context.go(routeLogin);
  }

  void _showExpiredSnackbar() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text(_kSessionExpired)));
  }

  void _onTapAddAccount() {
    // Drop the active session locally but KEEP the accounts list so the
    // user can flip back. Logout body=skipForget so the current row stays
    // visible while the user signs into the new account.
    Navigator.of(context).maybePop();
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    // Fire-and-forget; resetState awaits internally on next switch.
    ref.read(cryptoProvider.notifier).resetState();
    ref.read(authProvider.notifier).logout(forgetAccount: false);
    context.go(routeLogin);
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
