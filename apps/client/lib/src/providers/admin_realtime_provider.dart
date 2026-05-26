import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// Headline metrics from `GET /api/admin/stats/realtime` (#681 Phase 1).
///
/// Mirrors `RealtimeStats` in `apps/server/src/routes/admin.rs` — when the
/// server grows a new metric, add it here and the corresponding card in
/// `admin_dashboard_screen.dart`.
@immutable
class AdminRealtimeStats {
  final int connectedSessions;
  final PlatformBreakdown connectedSessionsByPlatform;
  final double messagesPerSec;
  final int activeVoiceRooms;
  final int dbPoolInFlight;
  final int dbPoolMax;

  const AdminRealtimeStats({
    required this.connectedSessions,
    required this.connectedSessionsByPlatform,
    required this.messagesPerSec,
    required this.activeVoiceRooms,
    required this.dbPoolInFlight,
    required this.dbPoolMax,
  });

  factory AdminRealtimeStats.fromJson(Map<String, dynamic> json) {
    return AdminRealtimeStats(
      connectedSessions: _asInt(json['connected_sessions']),
      connectedSessionsByPlatform: PlatformBreakdown.fromJson(
        json['connected_sessions_by_platform'] as Map<String, dynamic>? ??
            const {},
      ),
      messagesPerSec: _asDouble(json['messages_per_sec']),
      activeVoiceRooms: _asInt(json['active_voice_rooms']),
      dbPoolInFlight: _asInt(json['db_pool_in_flight']),
      dbPoolMax: _asInt(json['db_pool_max']),
    );
  }
}

@immutable
class PlatformBreakdown {
  final int web;
  final int mobile;
  final int desktop;
  final int unknown;

  const PlatformBreakdown({
    required this.web,
    required this.mobile,
    required this.desktop,
    required this.unknown,
  });

  factory PlatformBreakdown.fromJson(Map<String, dynamic> json) {
    return PlatformBreakdown(
      web: _asInt(json['web']),
      mobile: _asInt(json['mobile']),
      desktop: _asInt(json['desktop']),
      unknown: _asInt(json['unknown']),
    );
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0.0;
}

/// Discriminant set by [AdminRealtimeNotifier] when the server signals that
/// the access token is too old for admin routes. The dashboard renders a
/// distinct surface for this (a toast plus a friendlier message) so the
/// operator knows to re-enter their password — the actual re-auth prompt
/// is intentionally deferred to #681 Phase 1.5.
class AdminReauthRequired implements Exception {
  const AdminReauthRequired();
  @override
  String toString() => 'reauth_required';
}

/// 403 from the server's [`AdminUser`] extractor. Surfaced as a typed
/// exception so the screen can render a friendlier message instead of
/// the raw HTTP error.
class AdminForbidden implements Exception {
  const AdminForbidden();
  @override
  String toString() => 'forbidden';
}

class AdminHttpFailure implements Exception {
  final int statusCode;
  final String message;
  const AdminHttpFailure(this.statusCode, this.message);
  @override
  String toString() => message;
}

/// Poll cadence for the dashboard. Five seconds is a sensible trade-off
/// between freshness and load: the server-side endpoint does one cheap
/// SELECT plus a DashMap snapshot, but the dashboard is not the place to
/// turn a single operator into a constant-RPS source either.
const _pollInterval = Duration(seconds: 5);

final adminRealtimeProvider =
    AsyncNotifierProvider.autoDispose<
      AdminRealtimeNotifier,
      AdminRealtimeStats
    >(AdminRealtimeNotifier.new);

class AdminRealtimeNotifier
    extends AutoDisposeAsyncNotifier<AdminRealtimeStats> {
  Timer? _timer;

  @override
  Future<AdminRealtimeStats> build() {
    // Schedule the recurring poll; cancel it when this notifier is disposed
    // (autoDispose semantics — leaving the screen tears down the timer).
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _tick());
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return _load();
  }

  Future<void> _tick() async {
    // Skip if previous request still in flight.
    if (state.isLoading || state.isRefreshing) return;
    final next = await AsyncValue.guard(_load);
    // AsyncValue.guard preserves last-good data on transient error → stale indicator.
    state = next;
  }

  Future<AdminRealtimeStats> _load() async {
    final serverUrl = ref.read(serverUrlProvider);
    final auth = ref.read(authProvider.notifier);
    final response = await auth.authenticatedRequest(
      (token) => http.get(
        Uri.parse('$serverUrl/api/admin/stats/realtime'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    switch (response.statusCode) {
      case 200:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return AdminRealtimeStats.fromJson(json);
      case 401:
        // Accept either code:"reauth-required" or WWW-Authenticate header.
        final wwwAuth = response.headers['www-authenticate'] ?? '';
        if (wwwAuth.contains('reauth_required') ||
            response.body.contains('reauth-required')) {
          throw const AdminReauthRequired();
        }
        throw const AdminHttpFailure(
          401,
          'Session expired — please sign in again',
        );
      case 403:
        throw const AdminForbidden();
      default:
        throw AdminHttpFailure(
          response.statusCode,
          'Failed to load realtime stats (HTTP ${response.statusCode})',
        );
    }
  }

  /// Manual refresh (e.g. pull-to-refresh, refresh button).
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }
}
