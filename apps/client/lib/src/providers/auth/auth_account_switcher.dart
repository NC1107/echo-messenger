part of 'auth_provider.dart';

/// Multi-account switcher slice of the auth notifier.
///
/// Companion to [AuthTokenStorageMixin] / [AuthTokenRefreshMixin]: these
/// helpers maintain the [AccountsStorage] list that backs the
/// `AccountSwitcherSheet`. On each successful `login`/`register` the
/// account is upserted and pinned as active; `logout` optionally drops
/// it; `switchTo` mints a fresh access token for a stored account using
/// its persisted refresh token (or the HttpOnly cookie on web) and
/// re-hydrates [AuthState].
///
/// Lives as a `part of 'auth_provider.dart'` so it can mutate `state` and
/// reach the private storage helpers in [AuthTokenStorageMixin].
mixin AuthAccountSwitcherMixin on Notifier<AuthState>, AuthTokenStorageMixin {
  /// Visible-for-overriding hook for tests; defaults to the shared
  /// singleton-style instance backed by [SecureKeyStore].
  AccountsStorage get accountsStorage =>
      _accountsStorageOverride ?? _sharedAccountsStorage;

  AccountsStorage? _accountsStorageOverride;
  static final AccountsStorage _sharedAccountsStorage = AccountsStorage();

  /// Test seam: swap in a fake storage for switcher unit tests.
  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setAccountsStorageForTest(AccountsStorage storage) {
    _accountsStorageOverride = storage;
  }

  /// Read the current persisted accounts snapshot. UI surfaces (sheet,
  /// user menu) call this to render rows.
  Future<AccountsSnapshot> listAccounts() => accountsStorage.load();

  /// Upsert the freshly-authenticated account into the switcher list and
  /// mark it active. Called from [AuthNotifier.login] / .register after
  /// state is hydrated.
  ///
  /// Web stores no refresh token (cookie-only); the row still exists so
  /// the switcher can drive a cookie-based refresh on tap.
  Future<void> _recordActiveAccount({
    required String userId,
    required String username,
    required String? refreshToken,
    String? avatarUrl,
  }) async {
    try {
      final account = StoredAccount(
        userId: userId,
        username: username,
        avatarUrl: avatarUrl,
        serverUrl: _serverUrl,
        refreshToken: kIsWeb ? '' : (refreshToken ?? ''),
        lastUsed: DateTime.now(),
      );
      final snap = await accountsStorage.upsertAccount(account);
      // Find the upserted row (the storage may have stamped lastUsed) and
      // pin it as the active pointer.
      final matched = snap.accounts.firstWhere(
        (a) => a.id == account.id,
        orElse: () => account,
      );
      await accountsStorage.setActiveAccount(matched.id);
    } catch (e) {
      // Switcher persistence is non-fatal: a failed write must not abort
      // a successful login. The next launch will simply not have this
      // account in the list.
      debugPrint('[Auth] _recordActiveAccount failed: $e');
    }
  }

  /// Drop the currently-active account from the switcher list. Returns
  /// the *next* account that the caller can immediately switch to (most
  /// recently used among the survivors), or null when no other account
  /// is stored.
  Future<StoredAccount?> _forgetActiveAccount() async {
    try {
      final snap = await accountsStorage.load();
      final active = snap.active;
      if (active == null) return _mostRecent(snap.accounts);
      final after = await accountsStorage.removeAccount(active.id);
      return _mostRecent(after.accounts);
    } catch (e) {
      debugPrint('[Auth] _forgetActiveAccount failed: $e');
      return null;
    }
  }

  StoredAccount? _mostRecent(List<StoredAccount> accounts) {
    if (accounts.isEmpty) return null;
    final sorted = [...accounts]
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return sorted.first;
  }

  /// Activate [accountId] in the switcher: mints a fresh access token
  /// against the account's persisted refresh token (or HttpOnly cookie
  /// on web), updates [serverUrlProvider] if the origin differs, and
  /// rebuilds [AuthState] under the new identity.
  ///
  /// Returns true on success; false when the refresh failed (caller is
  /// expected to surface a "Session expired" snackbar and navigate the
  /// user to the login screen with the username pre-filled).
  Future<bool> switchToAccount(String accountId) async {
    final snap = await accountsStorage.load();
    StoredAccount? target;
    for (final a in snap.accounts) {
      if (a.id == accountId) {
        target = a;
        break;
      }
    }
    if (target == null) return false;

    await _swapServerUrl(target.serverUrl);
    _resetCryptoState();
    final ok = await _hydrateAccount(target);
    if (ok) {
      await accountsStorage.setActiveAccount(target.id);
      await accountsStorage.upsertAccount(
        target.copyWith(lastUsed: DateTime.now()),
      );
      BackgroundService.instance.start();
    }
    return ok;
  }

  /// Update [serverUrlProvider] to [url] in-place. Skips the full
  /// `switchTo` ceremony (which does a logout transaction) — we are
  /// about to mint a new session under a different identity anyway.
  Future<void> _swapServerUrl(String url) async {
    final current = ref.read(serverUrlProvider);
    if (current == url) return;
    await ref.read(serverUrlProvider.notifier).setUrl(url);
  }

  /// Clear in-memory crypto state so the new account does not see the
  /// previous user's Signal sessions. Pure in-memory wipe — secure
  /// storage stays scoped per-user so the persistent material survives.
  void _resetCryptoState() {
    SecureKeyStore.instance.clearUserScope();
    UserDataDir.instance.clearUser();
  }

  /// Mint a fresh access token for [account] and rebuild [AuthState].
  ///
  /// Native: POSTs the stored refresh token in the body.
  /// Web: POSTs `{}` so the browser attaches the HttpOnly cookie.
  Future<bool> _hydrateAccount(StoredAccount account) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final body = (kIsWeb || account.refreshToken.isEmpty)
          ? '{}'
          : jsonEncode({'refresh_token': account.refreshToken});

      final client = buildHttpClient();
      final http.Response response;
      try {
        response = await client
            .post(
              Uri.parse('${account.serverUrl}/api/auth/refresh'),
              headers: _kJsonHeaders,
              body: body,
            )
            .timeout(const Duration(seconds: 15));
      } finally {
        client.close();
      }

      if (response.statusCode != 200) {
        state = const AuthState();
        return false;
      }
      return _applyHydratedSession(account, response.body);
    } catch (e) {
      debugPrint('[Auth] switchToAccount hydrate failed: $e');
      state = const AuthState();
      return false;
    }
  }

  /// Decode the /api/auth/refresh response, persist tokens, and publish
  /// the new [AuthState]. Split out of [_hydrateAccount] to keep the
  /// outer method's cognitive complexity inside the S3776 budget.
  Future<bool> _applyHydratedSession(
    StoredAccount account,
    String responseBody,
  ) async {
    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final newAccessToken = data['access_token'] as String;
    final newRefreshToken = kIsWeb
        ? null
        : (data['refresh_token'] as String? ?? account.refreshToken);
    final userId = data['user_id'] as String? ?? account.userId;
    final username = data['username'] as String? ?? account.username;
    final isAdmin = data['is_admin'] as bool? ?? false;

    await _storeTokens(
      accessToken: newAccessToken,
      refreshToken: newRefreshToken ?? '',
      userId: userId,
      username: username,
    );
    await _setUserScope(userId);

    state = AuthState(
      isLoggedIn: true,
      userId: userId,
      username: username,
      token: newAccessToken,
      refreshToken: newRefreshToken,
      avatarUrl: account.avatarUrl,
      isAdmin: isAdmin,
    );
    return true;
  }
}
