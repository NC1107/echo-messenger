import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/participated_thread.dart';
import 'auth/auth_provider.dart';
import 'server_url_provider.dart';

part 'participated_threads_provider.g.dart';

/// Immutable state for the "Threads" sidebar entry + screen (#449).
class ParticipatedThreadsState {
  final List<ParticipatedThread> threads;
  final bool isLoading;
  final String? error;

  const ParticipatedThreadsState({
    this.threads = const [],
    this.isLoading = false,
    this.error,
  });

  ParticipatedThreadsState copyWith({
    List<ParticipatedThread>? threads,
    bool? isLoading,
    String? error,
  }) {
    return ParticipatedThreadsState(
      threads: threads ?? this.threads,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  /// Count of threads with at least one unread reply — drives the sidebar
  /// badge.
  int get unreadThreadCount =>
      threads.where((t) => t.unreadReplyCount > 0).length;
}

/// Fetches and caches the list of threads the authenticated user has
/// participated in. Lives for the app session (keepAlive) so the sidebar
/// badge stays warm; call [load] / [refresh] on demand.
///
/// WS reactivity is wired at the screen / sidebar level via
/// `websocketProvider`'s reply-bearing message stream — when a
/// `MessageRelayed`-style event arrives with a non-null `reply_to_id`,
/// listeners call [refresh] to pick up the new thread row.
@Riverpod(keepAlive: true)
class ParticipatedThreads extends _$ParticipatedThreads {
  @override
  ParticipatedThreadsState build() => const ParticipatedThreadsState();

  /// Public entry used by tests so we can swap in a fake `http.Client`
  /// without overriding the auth + server-url providers. Production code
  /// goes through [_authedGet] which uses the standard 401-retry wrapper.
  http.Client? debugHttpClientOverride;

  /// Tests set this to disable the network round-trip — `load()` becomes
  /// a no-op so widget tests can drive the screen entirely from
  /// [debugSetState] without the dummy `HttpClient` 400s the test binding
  /// returns. Production never touches this.
  bool debugSuppressAutoLoad = false;

  /// Fetch the current page of participated threads, replacing in-memory
  /// state. No-ops when already loading.
  Future<void> load() async {
    if (debugSuppressAutoLoad) return;
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final uri = Uri.parse('$serverUrl/api/threads/participated');
      final response = await _authedGet(uri);
      if (response.statusCode != 200) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load threads (${response.statusCode})',
        );
        return;
      }
      final parsed = _parseList(response.body);
      state = ParticipatedThreadsState(threads: parsed, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Re-fetch silently in the background (no spinner). Used by WS listeners
  /// when a reply event arrives.
  Future<void> refresh() async {
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final uri = Uri.parse('$serverUrl/api/threads/participated');
      final response = await _authedGet(uri);
      if (response.statusCode != 200) return;
      state = state.copyWith(threads: _parseList(response.body));
    } catch (_) {
      // Silent: refresh failures fall back to whatever's currently shown.
    }
  }

  /// Test-only setter that injects a pre-baked state. Used by widget
  /// tests so we can render the screen without booting the auth/HTTP
  /// stack.
  void debugSetState(ParticipatedThreadsState next) {
    state = next;
  }

  // S107: helper signature is intentionally narrow; cognitive complexity
  // stays under budget by isolating the auth retry from the parsing path.
  Future<http.Response> _authedGet(Uri uri) {
    final client = debugHttpClientOverride;
    if (client != null) {
      // Tests bypass the auth-provider chain and inject a stub client
      // directly. Production code never lands here.
      return client.get(uri);
    }
    return ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          ),
        );
  }

  List<ParticipatedThread> _parseList(String body) {
    final raw = jsonDecode(body);
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ParticipatedThread.fromJson)
        .toList(growable: false);
  }
}
