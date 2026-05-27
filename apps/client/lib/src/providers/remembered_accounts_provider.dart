/// Persistent list of accounts that have signed in on this device.
///
/// Chrome-style "Who's using Echo?" surface — when the user lands on
/// the login screen, this provider feeds the quick-switch row at the
/// top. Tap an account → username pre-filled and focus moves to the
/// password field. Logging out never removes an account from this list
/// (the user's data also stays on device, so the next login is fast).
///
/// Stored as a single JSON-encoded list in SharedPreferences. No
/// passwords or tokens here — purely identity hints (userId, username,
/// serverUrl, avatarUrl, last-used timestamp) so the picker is
/// recognisable.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'remembered_accounts_provider.g.dart';

const _kRememberedAccountsKey = 'echo_remembered_accounts_v1';
const _kMaxRemembered = 8;

/// One row in the remembered-accounts list. Identifying information
/// only — never the access or refresh token.
@immutable
class RememberedAccount {
  final String userId;
  final String username;
  final String serverUrl;
  final String? avatarUrl;
  final DateTime lastUsedAt;

  const RememberedAccount({
    required this.userId,
    required this.username,
    required this.serverUrl,
    required this.lastUsedAt,
    this.avatarUrl,
  });

  RememberedAccount copyWith({
    String? username,
    String? avatarUrl,
    DateTime? lastUsedAt,
  }) {
    return RememberedAccount(
      userId: userId,
      username: username ?? this.username,
      serverUrl: serverUrl,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'server_url': serverUrl,
    'avatar_url': avatarUrl,
    'last_used_at': lastUsedAt.toIso8601String(),
  };

  static RememberedAccount? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'] as String?;
    final username = json['username'] as String?;
    final serverUrl = json['server_url'] as String?;
    if (userId == null || username == null || serverUrl == null) return null;
    final lastUsedRaw = json['last_used_at'] as String?;
    return RememberedAccount(
      userId: userId,
      username: username,
      serverUrl: serverUrl,
      avatarUrl: json['avatar_url'] as String?,
      lastUsedAt:
          (lastUsedRaw != null ? DateTime.tryParse(lastUsedRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

@Riverpod(keepAlive: true)
class RememberedAccounts extends _$RememberedAccounts {
  @override
  List<RememberedAccount> build() {
    // Fire-and-forget initial load; UI renders empty until it lands.
    Future.microtask(_load);
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kRememberedAccountsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List;
      final accounts =
          decoded
              .whereType<Map<String, dynamic>>()
              .map(RememberedAccount.fromJson)
              .whereType<RememberedAccount>()
              .toList()
            ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
      state = accounts;
    } catch (_) {
      // Corrupt payload: drop silently. The list is purely a convenience
      // surface; a clean slate is fine.
    }
  }

  Future<void> _persist(List<RememberedAccount> next) async {
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRememberedAccountsKey,
        jsonEncode(next.map((a) => a.toJson()).toList()),
      );
    } catch (_) {
      // Best-effort: the user can still log in even if persistence
      // failed; the row just won't survive a restart.
    }
  }

  /// Upsert by `(userId, serverUrl)`. Called on successful login so
  /// repeat sign-ins refresh the tile order + cached avatar.
  Future<void> upsert({
    required String userId,
    required String username,
    required String serverUrl,
    String? avatarUrl,
  }) async {
    final now = DateTime.now();
    final next = [
      RememberedAccount(
        userId: userId,
        username: username,
        serverUrl: serverUrl,
        avatarUrl: avatarUrl,
        lastUsedAt: now,
      ),
      for (final acc in state)
        if (acc.userId != userId || acc.serverUrl != serverUrl) acc,
    ];
    // Cap the list — older accounts fall off the end.
    while (next.length > _kMaxRemembered) {
      next.removeLast();
    }
    await _persist(next);
  }

  /// Drop a single remembered account (user tapped "Forget" on a tile).
  /// Does NOT delete the on-disk keys / cache — they're preserved so a
  /// future re-login still has its history.
  Future<void> forget({
    required String userId,
    required String serverUrl,
  }) async {
    final next = state
        .where((a) => a.userId != userId || a.serverUrl != serverUrl)
        .toList();
    await _persist(next);
  }

  /// Wipe the entire list (rarely needed; exposed for an explicit
  /// "Clear sign-in suggestions" affordance).
  Future<void> clear() => _persist(const []);
}
