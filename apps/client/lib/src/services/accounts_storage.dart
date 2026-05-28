/// Multi-account persistence layer.
///
/// Today the app only remembers ONE logged-in user at a time. When the
/// user signs out we drop the session and route them back to the login
/// screen — even if they had a second account on the device the day
/// before. [AccountsStorage] is the storage half of the
/// Discord/Slack-style switcher: it keeps a list of [StoredAccount]
/// records (each is "username on a server" plus the refresh token that
/// can mint a new access token) and a pointer to the currently-active
/// account.
///
/// Storage layout:
///   * Refresh tokens are sensitive — the whole list is JSON-encoded and
///     written to [SecureKeyStore]'s **global** scope under
///     [_kAccountsKey]. The list is treated as opaque blob; we re-encode
///     on every mutation. This matches how the legacy auth flow already
///     persists `echo_auth_refresh_token` (global scope, secure storage).
///   * The active account id lives in [SharedPreferences] under
///     [_kActiveAccountKey] because (a) it isn't sensitive and (b) the
///     splash screen reads it before any secure-storage warm-up.
///   * On web we still avoid writing refresh tokens to JS-accessible
///     storage — the server-issued HttpOnly cookie does that job. The
///     [StoredAccount.refreshToken] field is left empty on web; the
///     switcher just records which account is active so the existing
///     cookie-based [/api/auth/refresh] path can rebuild the session.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_key_store.dart';

/// One row in the account switcher.
///
/// Equality is by [userId] + [serverUrl] (the same human can have an
/// account on multiple servers and we want both to be selectable).
@immutable
class StoredAccount {
  /// Server-issued user id. Stable across sessions; used as the switcher
  /// row's primary key and as the pointer for "active account".
  final String userId;

  /// Display name used by the row's label.
  final String username;

  /// Server-relative or absolute avatar URL. Resolved against
  /// [serverUrl] by the rendering widget so the same path keeps working
  /// after a server switch.
  final String? avatarUrl;

  /// HTTP origin the account belongs to (e.g.
  /// `https://us-east.echo-messenger.us`). The switcher flips
  /// [serverUrlProvider] to this value when activating the account.
  final String serverUrl;

  /// Native refresh token. Empty on web (cookie path) and on accounts
  /// that haven't completed a fresh login since the upgrade.
  final String refreshToken;

  /// Wall-clock time of last activation. Drives the row sort order so
  /// the most-recently-used account floats to the top.
  final DateTime lastUsed;

  const StoredAccount({
    required this.userId,
    required this.username,
    required this.serverUrl,
    required this.refreshToken,
    required this.lastUsed,
    this.avatarUrl,
  });

  /// Stable id used as the active-account pointer and as the dedupe key
  /// inside the persisted list.
  String get id => '$userId@$serverUrl';

  StoredAccount copyWith({
    String? userId,
    String? username,
    String? avatarUrl,
    String? serverUrl,
    String? refreshToken,
    DateTime? lastUsed,
  }) {
    return StoredAccount(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      serverUrl: serverUrl ?? this.serverUrl,
      refreshToken: refreshToken ?? this.refreshToken,
      lastUsed: lastUsed ?? this.lastUsed,
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'avatar_url': avatarUrl,
    'server_url': serverUrl,
    'refresh_token': refreshToken,
    'last_used': lastUsed.toIso8601String(),
  };

  static StoredAccount? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'] as String?;
    final username = json['username'] as String?;
    final serverUrl = json['server_url'] as String?;
    if (userId == null || username == null || serverUrl == null) return null;
    if (userId.isEmpty || serverUrl.isEmpty) return null;
    final lastUsedRaw = json['last_used'] as String?;
    final lastUsed = lastUsedRaw != null
        ? DateTime.tryParse(lastUsedRaw) ??
              DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(0);
    return StoredAccount(
      userId: userId,
      username: username,
      avatarUrl: json['avatar_url'] as String?,
      serverUrl: serverUrl,
      refreshToken: (json['refresh_token'] as String?) ?? '',
      lastUsed: lastUsed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StoredAccount &&
      other.userId == userId &&
      other.username == username &&
      other.avatarUrl == avatarUrl &&
      other.serverUrl == serverUrl &&
      other.refreshToken == refreshToken &&
      other.lastUsed == lastUsed;

  @override
  int get hashCode => Object.hash(
    userId,
    username,
    avatarUrl,
    serverUrl,
    refreshToken,
    lastUsed,
  );
}

/// Snapshot returned by [AccountsStorage.load]. Pairs the persisted list
/// with the active-account pointer; UI layers consume both.
@immutable
class AccountsSnapshot {
  final List<StoredAccount> accounts;
  final String? activeAccountId;

  const AccountsSnapshot({
    required this.accounts,
    required this.activeAccountId,
  });

  /// Convenience lookup. Returns null when there is no active pointer or
  /// the pointer references an id that is no longer in [accounts].
  StoredAccount? get active {
    final id = activeAccountId;
    if (id == null || id.isEmpty) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// Secure-storage backed CRUD over the multi-account list.
///
/// Pure I/O — no business logic about *when* to add or switch
/// accounts. That lives in the provider layer so the storage object is
/// trivially mockable for tests.
class AccountsStorage {
  AccountsStorage({SecureKeyStore? secureStore})
    : _secureStore = secureStore ?? SecureKeyStore.instance;

  final SecureKeyStore _secureStore;

  /// Single secure-storage key holding the JSON-encoded list. Versioned
  /// suffix so future schema migrations can detect old payloads instead
  /// of silently overwriting them.
  static const String _kAccountsKey = 'echo_accounts_v1';

  /// SharedPreferences key for the active account pointer.
  static const String _kActiveAccountKey = 'echo_active_account_id';

  /// Read the persisted list + active pointer.
  ///
  /// Failure to read secure storage is treated as "no accounts" —
  /// matches the existing auth provider's behaviour when the keyring is
  /// locked, since blocking the UI on a backend outage would only
  /// leave the user stuck at the login screen with no recourse.
  Future<AccountsSnapshot> load() async {
    final list = await _readList();
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_kActiveAccountKey);
    return AccountsSnapshot(accounts: list, activeAccountId: activeId);
  }

  /// Insert or update an account by [StoredAccount.id]. Bumps
  /// [StoredAccount.lastUsed] to "now" so the row floats to the top of
  /// the switcher. Returns the resulting snapshot.
  Future<AccountsSnapshot> upsertAccount(StoredAccount account) async {
    final existing = await _readList();
    final now = DateTime.now();
    final stamped = account.copyWith(lastUsed: now);
    final merged = <StoredAccount>[];
    var replaced = false;
    for (final a in existing) {
      if (a.id == stamped.id) {
        merged.add(stamped);
        replaced = true;
      } else {
        merged.add(a);
      }
    }
    if (!replaced) merged.add(stamped);
    await _writeList(merged);
    return AccountsSnapshot(
      accounts: merged,
      activeAccountId: await _readActiveId(),
    );
  }

  /// Remove the account with [accountId] from the list. If it was the
  /// active account, the pointer is cleared so the caller can decide
  /// what to activate next.
  Future<AccountsSnapshot> removeAccount(String accountId) async {
    final existing = await _readList();
    final filtered = existing.where((a) => a.id != accountId).toList();
    await _writeList(filtered);
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_kActiveAccountKey);
    if (activeId == accountId) {
      await prefs.remove(_kActiveAccountKey);
      return AccountsSnapshot(accounts: filtered, activeAccountId: null);
    }
    return AccountsSnapshot(accounts: filtered, activeAccountId: activeId);
  }

  /// Set the active account pointer. Does NOT validate the id against
  /// the persisted list — callers are expected to pass an id from
  /// [load]/[upsertAccount].
  Future<void> setActiveAccount(String? accountId) async {
    final prefs = await SharedPreferences.getInstance();
    if (accountId == null || accountId.isEmpty) {
      await prefs.remove(_kActiveAccountKey);
    } else {
      await prefs.setString(_kActiveAccountKey, accountId);
    }
  }

  /// Wipe both the list and the active pointer. Used by the legacy
  /// "Forget this device" path; the normal logout flow goes through
  /// [removeAccount] + [setActiveAccount].
  Future<void> clear() async {
    try {
      await _secureStore.deleteGlobal(_kAccountsKey);
    } catch (e) {
      debugPrint('[Accounts] clear (secure) failed: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kActiveAccountKey);
    } catch (e) {
      debugPrint('[Accounts] clear (prefs) failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<String?> _readActiveId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kActiveAccountKey);
    } catch (e) {
      debugPrint('[Accounts] _readActiveId failed: $e');
      return null;
    }
  }

  Future<List<StoredAccount>> _readList() async {
    String? raw;
    try {
      raw = await _secureStore.readGlobal(_kAccountsKey);
    } catch (e) {
      // Keyring locked / web localStorage broken: treat as empty list
      // rather than throwing — the splash screen still routes to the
      // active legacy session via tryAutoLogin if it can.
      debugPrint('[Accounts] _readList (secure) failed: $e');
      return const [];
    }
    if (raw == null || raw.isEmpty) return const [];
    return _decode(raw);
  }

  Future<void> _writeList(List<StoredAccount> accounts) async {
    final encoded = jsonEncode(accounts.map((a) => a.toJson()).toList());
    try {
      await _secureStore.writeGlobal(_kAccountsKey, encoded);
    } catch (e) {
      debugPrint('[Accounts] _writeList failed: $e');
      rethrow;
    }
  }

  List<StoredAccount> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(StoredAccount.fromJson)
          .whereType<StoredAccount>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('[Accounts] decode failed: $e');
      return const [];
    }
  }
}
