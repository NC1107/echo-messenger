import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/push_token_service.dart';
import 'auth_provider.dart';
import 'websocket_provider.dart';

part 'server_url_provider.g.dart';

/// Default server URL for production deployment.
///
/// Phase 2 of the domain migration (#1063) — moved off the apex onto the
/// us-east regional alias. The apex is becoming the marketing site;
/// `us-east.echo-messenger.us` is the centralised server's permanent home.
/// Self-hosters override via the auth-screen server picker as before.
const defaultServerUrl = 'https://us-east.echo-messenger.us';

/// Pre-migration apex (#1063). After Phase 2 the apex became the marketing
/// site and 405s every `/api/*` call, so any install still pinned to it is
/// silently locked out of login/register. [ServerUrlNotifier.load] repoints it
/// to [defaultServerUrl] on launch so those installs self-heal.
const _legacyApexUrl = 'https://echo-messenger.us';

/// SharedPreferences keys.
const _prefsKeyServerUrl = 'echo_server_url';
const _prefsKeyKnownServers = 'echo_known_servers';

/// Pre-migration auth keys read for the one-time migration into
/// [KnownServer]. Defined here (instead of pulling from auth_provider) to
/// avoid forcing AuthNotifier to expose its private constants.
const _legacyKeyUsername = 'echo_auth_username';

/// Metadata for a server the user has registered or logged into. Persisted as
/// JSON in SharedPreferences so it survives app restarts. Only the URL is
/// load-bearing; the rest is UX (last-used username, last-seen timestamp,
/// optional pinned server identity).
@immutable
class KnownServer {
  final String url;
  final String? lastUsername;
  final DateTime lastSeen;

  /// Stable server UUID returned by `GET /api/server-info`. Pinning is a
  /// future-PR feature; we currently capture it opportunistically when the
  /// "Add server" flow runs the pre-flight check.
  final String? serverId;

  const KnownServer({
    required this.url,
    required this.lastSeen,
    this.lastUsername,
    this.serverId,
  });

  KnownServer copyWith({
    String? url,
    String? lastUsername,
    DateTime? lastSeen,
    String? serverId,
  }) {
    return KnownServer(
      url: url ?? this.url,
      lastUsername: lastUsername ?? this.lastUsername,
      lastSeen: lastSeen ?? this.lastSeen,
      serverId: serverId ?? this.serverId,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'last_username': lastUsername,
    'last_seen': lastSeen.toIso8601String(),
    'server_id': serverId,
  };

  static KnownServer? fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String?;
    if (url == null || url.isEmpty) return null;
    final lastSeenStr = json['last_seen'] as String?;
    final lastSeen = lastSeenStr != null
        ? DateTime.tryParse(lastSeenStr) ??
              DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(0);
    return KnownServer(
      url: url,
      lastSeen: lastSeen,
      lastUsername: json['last_username'] as String?,
      serverId: json['server_id'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KnownServer &&
      other.url == url &&
      other.lastUsername == lastUsername &&
      other.lastSeen == lastSeen &&
      other.serverId == serverId;

  @override
  int get hashCode => Object.hash(url, lastUsername, lastSeen, serverId);
}

/// Companion provider exposing the persisted list of known servers. Updated
/// in lockstep with [serverUrlProvider] by [ServerUrlNotifier.switchTo],
/// [addKnownServer], [forget], and [recordLastUsername].
///
/// Migrated from `StateNotifier` to `@riverpod` codegen (#770, 2026-05-14).
@Riverpod(keepAlive: true)
class KnownServersNotifier extends _$KnownServersNotifier {
  @override
  List<KnownServer> build() => const [];

  /// Load from SharedPreferences. Idempotent.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    state = readKnownServers(prefs);
  }

  /// Replace the in-memory list AND persist to disk.
  Future<void> setAll(List<KnownServer> servers) async {
    state = List<KnownServer>.unmodifiable(servers);
    final prefs = await SharedPreferences.getInstance();
    await persistKnownServers(prefs, servers);
  }

  /// Test-only: publish a list without writing to SharedPreferences. Used by
  /// [ServerUrlNotifier.load] when the on-disk state already matches.
  void publish(List<KnownServer> servers) {
    state = List<KnownServer>.unmodifiable(servers);
  }

  /// Read the JSON list out of SharedPreferences. Visible to the URL
  /// notifier so it can run the one-time migration during `load()`.
  static List<KnownServer> readKnownServers(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKeyKnownServers);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(KnownServer.fromJson)
          .whereType<KnownServer>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> persistKnownServers(
    SharedPreferences prefs,
    List<KnownServer> servers,
  ) async {
    final encoded = jsonEncode(servers.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKeyKnownServers, encoded);
  }
}

/// Riverpod provider holding the active server URL. Backwards-compatible:
/// state is still a `String`, so the ~100 existing call sites continue to
/// work unchanged. Known-server metadata lives in [knownServersProvider].
///
/// Migrated from `StateNotifier` to `@riverpod` codegen (#770, 2026-05-14).
@Riverpod(keepAlive: true)
class ServerUrlNotifier extends _$ServerUrlNotifier {
  @override
  String build() => defaultServerUrl;

  /// Load the active URL + known-servers list from SharedPreferences. Runs
  /// the one-time migration that synthesises a [KnownServer] entry from
  /// pre-existing global keys so the new UI has something to render and
  /// the active session continues uninterrupted.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKeyServerUrl);
    var url = (stored != null && stored.isNotEmpty) ? stored : defaultServerUrl;

    // One-time repoint off the dead apex (#1063): it now serves the marketing
    // site and 405s the API, so anyone pinned to it can't log in. Move them to
    // the regional alias and persist so the change sticks.
    if (url == _legacyApexUrl) {
      url = defaultServerUrl;
      await prefs.setString(_prefsKeyServerUrl, url);
    }
    state = url;

    // Update the companion known-servers provider, repointing any apex tile.
    final original = KnownServersNotifier.readKnownServers(prefs);
    final repointed = _repointLegacyApex(original);
    final migrated = _maybeMigrate(prefs, url, repointed);
    final notifier = ref.read(knownServersProvider.notifier);
    if (!_listEquals(original, migrated)) {
      await notifier.setAll(migrated);
    } else {
      // Still publish the current list so widgets can read it on first
      // build without waiting for the next mutation.
      notifier.publish(migrated);
    }
  }

  /// Update the server URL in-place WITHOUT logging out. Used by tests and
  /// the legacy callers; new flows should funnel through [switchTo] instead.
  Future<void> setUrl(String url) async {
    final normalized = _normalize(url);
    state = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyServerUrl, normalized);
  }

  /// Reset to the default server URL.
  Future<void> resetToDefault() async {
    state = defaultServerUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeyServerUrl);
  }

  /// Single entry point for changing servers. PR 2 invariant:
  /// **changing the server URL is a logout transaction.**
  ///
  /// Steps in order:
  ///   1. Logout against the OLD origin (clears refresh cookie on web,
  ///      revokes refresh tokens server-side).
  ///   2. Update the active URL state + persist.
  ///   3. Upsert the destination into the known-servers list with
  ///      `lastSeen = now()`.
  ///   4. Tear down the websocket so it does not keep talking to the old
  ///      server.
  ///
  /// The crypto keystore namespace and Hive message cache for both servers
  /// are intentionally left intact -- per-server scoping isolates them and
  /// re-login on a known server should pick up where it left off.
  Future<void> switchTo(String url) async {
    final normalized = _normalize(url);
    final oldUrl = state;
    final oldToken = ref.read(authProvider).token ?? '';

    // (0) Drop push tokens from the OLD origin while we still have a
    //     valid access token. Idempotent server-side, swallows errors.
    try {
      await PushTokenService.instance.deregister(
        serverUrl: oldUrl,
        authToken: oldToken,
      );
    } catch (e) {
      debugPrint('[ServerUrl] push deregister-on-switch ignored: $e');
    }

    // (1) Logout against the OLD origin so its cookie + refresh-token row
    //     are cleared even though we are about to flip the active URL.
    try {
      await ref.read(authProvider.notifier).logout(serverUrl: oldUrl);
    } catch (e) {
      // Logout failures must never block a server switch. The local state
      // is already cleared; the remote token will expire on its own.
      debugPrint('[ServerUrl] logout-on-switch ignored: $e');
    }

    // (2) Flip the URL state and persist.
    state = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyServerUrl, normalized);

    // (3) Upsert into known-servers.
    final knownNotifier = ref.read(knownServersProvider.notifier);
    final updated = _upsert(knownNotifier.state, normalized);
    await knownNotifier.setAll(updated);

    // (4) Tear down WS. The websocket provider also watches serverUrlProvider
    //     so this is belt-and-suspenders; the explicit disconnect avoids any
    //     in-flight reconnect from talking to the old origin.
    try {
      ref.read(websocketProvider.notifier).disconnect();
    } catch (_) {
      // Websocket may not be initialised yet (e.g. switching from the login
      // screen) -- not an error.
    }
  }

  /// Add a server to the known-servers list without making it active.
  /// Used by the "Add server" flow after a successful pre-flight check.
  Future<void> addKnownServer({
    required String url,
    String? serverId,
    String? lastUsername,
  }) async {
    final normalized = _normalize(url);
    final knownNotifier = ref.read(knownServersProvider.notifier);
    final updated = _upsert(
      knownNotifier.state,
      normalized,
      serverId: serverId,
      lastUsername: lastUsername,
      // Don't bump lastSeen for an add -- it surfaces in UI sort order, and
      // a server we have never logged into shouldn't outrank the active one.
      bumpLastSeen: false,
    );
    await knownNotifier.setAll(updated);
  }

  /// Remove a server from the known-servers list. Caller is responsible for
  /// also wiping scoped state (SecureKeyStore + Hive message cache).
  Future<void> forget(String url) async {
    final normalized = _normalize(url);
    final knownNotifier = ref.read(knownServersProvider.notifier);
    final updated = knownNotifier.state
        .where((s) => s.url != normalized)
        .toList(growable: false);
    await knownNotifier.setAll(updated);
  }

  /// Record the username last used to log into a known server. Called by
  /// auth flows so the next visit to that server can pre-fill the field.
  Future<void> recordLastUsername({
    required String url,
    required String username,
  }) async {
    final normalized = _normalize(url);
    final knownNotifier = ref.read(knownServersProvider.notifier);
    final updated = _upsert(
      knownNotifier.state,
      normalized,
      lastUsername: username,
    );
    await knownNotifier.setAll(updated);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _normalize(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  /// Upsert with the same merge semantics every caller needs.
  static List<KnownServer> _upsert(
    List<KnownServer> existing,
    String url, {
    String? serverId,
    String? lastUsername,
    bool bumpLastSeen = true,
  }) {
    final now = DateTime.now();
    final out = <KnownServer>[];
    var found = false;
    for (final s in existing) {
      if (s.url == url) {
        found = true;
        out.add(
          s.copyWith(
            serverId: serverId ?? s.serverId,
            lastUsername: lastUsername ?? s.lastUsername,
            lastSeen: bumpLastSeen ? now : s.lastSeen,
          ),
        );
      } else {
        out.add(s);
      }
    }
    if (!found) {
      out.add(
        KnownServer(
          url: url,
          lastSeen: bumpLastSeen ? now : DateTime.fromMillisecondsSinceEpoch(0),
          lastUsername: lastUsername,
          serverId: serverId,
        ),
      );
    }
    return out;
  }

  /// On first launch post-upgrade, synthesize a known-servers entry from the
  /// existing global `echo_server_url` + `echo_auth_username` keys so the
  /// active session continues uninterrupted and the new UI has something to
  /// render.
  static List<KnownServer> _maybeMigrate(
    SharedPreferences prefs,
    String activeUrl,
    List<KnownServer> existing,
  ) {
    if (existing.any((s) => s.url == activeUrl)) return existing;
    return _upsert(
      existing,
      activeUrl,
      lastUsername: prefs.getString(_legacyKeyUsername),
    );
  }

  /// Rewrite any known-server entry pinned to the dead apex to
  /// [defaultServerUrl], deduping into an existing alias entry (keeping the
  /// newer `lastSeen` and any captured `lastUsername`) and preserving order.
  static List<KnownServer> _repointLegacyApex(List<KnownServer> servers) {
    if (!servers.any((s) => s.url == _legacyApexUrl)) return servers;
    final merged = <String, KnownServer>{};
    for (final s in servers) {
      final mapped = s.url == _legacyApexUrl
          ? s.copyWith(url: defaultServerUrl)
          : s;
      final existing = merged[mapped.url];
      if (existing == null) {
        merged[mapped.url] = mapped;
      } else {
        final newer = mapped.lastSeen.isAfter(existing.lastSeen)
            ? mapped
            : existing;
        merged[mapped.url] = newer.copyWith(
          lastUsername: existing.lastUsername ?? mapped.lastUsername,
          serverId: existing.serverId ?? mapped.serverId,
        );
      }
    }
    // Preserve first-seen ordering by the post-rewrite URL.
    final seen = <String>{};
    final out = <KnownServer>[];
    for (final s in servers) {
      final url = s.url == _legacyApexUrl ? defaultServerUrl : s.url;
      if (seen.add(url)) out.add(merged[url]!);
    }
    return out;
  }

  static bool _listEquals(List<KnownServer> a, List<KnownServer> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Back-compat aliases preserving the legacy provider symbols used by the
/// ~100 existing call sites and tests. Riverpod codegen names the providers
/// after the notifier classes (`serverUrlNotifierProvider`,
/// `knownServersNotifierProvider`); we re-export the short names here so
/// nothing else needs to change.
final serverUrlProvider = serverUrlNotifierProvider;
final knownServersProvider = knownServersNotifierProvider;

/// Derive the WebSocket URL from the HTTP server URL.
///
/// `https://` becomes `wss://`, `http://` becomes `ws://`.
String wsUrlFromHttpUrl(String httpUrl) {
  if (httpUrl.startsWith('https://')) {
    return 'wss://${httpUrl.substring('https://'.length)}';
  } else if (httpUrl.startsWith('http://')) {
    return 'ws://${httpUrl.substring('http://'.length)}';
  }
  // Fallback: assume wss
  return 'wss://$httpUrl';
}
