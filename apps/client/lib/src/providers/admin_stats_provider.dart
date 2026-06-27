import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// Typed view of the `GET /api/admin/stats` response. Field set mirrors the
/// `AdminStats` struct in `apps/server/src/routes/admin.rs` — keep them in
/// sync if the server adds new metrics.
@immutable
class AdminStats {
  final int usersTotal;
  final int usersActive24h;
  final int messages24h;
  final int groupsTotal;
  final int onlineDevices;
  final int feedbackOpen;
  final int feedbackLast24h;

  const AdminStats({
    required this.usersTotal,
    required this.usersActive24h,
    required this.messages24h,
    required this.groupsTotal,
    required this.onlineDevices,
    required this.feedbackOpen,
    required this.feedbackLast24h,
  });

  factory AdminStats.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    return AdminStats(
      usersTotal: asInt(json['users_total']),
      usersActive24h: asInt(json['users_active_24h']),
      messages24h: asInt(json['messages_24h']),
      groupsTotal: asInt(json['groups_total']),
      onlineDevices: asInt(json['online_devices']),
      feedbackOpen: asInt(json['feedback_open']),
      feedbackLast24h: asInt(json['feedback_last_24h']),
    );
  }

  // S107: wide on purpose — immutable-state copyWith mirroring the field set.
  AdminStats copyWith({int? feedbackOpen}) => AdminStats(
    usersTotal: usersTotal,
    usersActive24h: usersActive24h,
    messages24h: messages24h,
    groupsTotal: groupsTotal,
    onlineDevices: onlineDevices,
    feedbackOpen: feedbackOpen ?? this.feedbackOpen,
    feedbackLast24h: feedbackLast24h,
  );
}

/// A single row out of `GET /api/admin/feedback`. Server wraps these in a
/// `{ "feedback": [...] }` envelope (see `routes::admin::list_feedback`).
@immutable
class FeedbackItem {
  final String id;
  final String userId;
  final String? username;
  final String title;
  final String body;
  final bool publicOk;
  final String status;
  final DateTime createdAt;

  const FeedbackItem({
    required this.id,
    required this.userId,
    required this.username,
    required this.title,
    required this.body,
    required this.publicOk,
    required this.status,
    required this.createdAt,
  });

  factory FeedbackItem.fromJson(Map<String, dynamic> json) {
    return FeedbackItem(
      id: json['id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      username: json['username'] as String?,
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      publicOk: json['public_ok'] as bool? ?? false,
      status: json['status'] as String? ?? 'open',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Combined view-model so the dashboard can render stats + feedback from a
/// single `AsyncValue`. Using one provider (instead of two parallel ones)
/// keeps the loading / error states aligned — a 403 from the gate, for
/// instance, should fail both panels together.
@immutable
class AdminDashboardData {
  final AdminStats stats;
  final List<FeedbackItem> feedback;

  const AdminDashboardData({required this.stats, required this.feedback});
}

final adminDashboardProvider =
    AsyncNotifierProvider.autoDispose<
      AdminDashboardNotifier,
      AdminDashboardData
    >(AdminDashboardNotifier.new);

class AdminDashboardNotifier
    extends AutoDisposeAsyncNotifier<AdminDashboardData> {
  @override
  Future<AdminDashboardData> build() => _load();

  Future<AdminDashboardData> _load() async {
    final serverUrl = ref.read(serverUrlProvider);
    final auth = ref.read(authProvider.notifier);

    Future<http.Response> getJson(String path) {
      return auth.authenticatedRequest(
        (token) => http.get(
          Uri.parse('$serverUrl$path'),
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
    }

    final statsRes = await getJson('/api/admin/stats');
    if (statsRes.statusCode != 200) {
      throw _AdminHttpError(
        'Failed to load admin stats (HTTP ${statsRes.statusCode})',
        statsRes.statusCode,
      );
    }
    final statsJson = jsonDecode(statsRes.body) as Map<String, dynamic>;
    final stats = AdminStats.fromJson(statsJson);

    final fbRes = await getJson('/api/admin/feedback');
    if (fbRes.statusCode != 200) {
      throw _AdminHttpError(
        'Failed to load feedback (HTTP ${fbRes.statusCode})',
        fbRes.statusCode,
      );
    }
    final fbDecoded = jsonDecode(fbRes.body);
    // Server returns `{ "feedback": [...] }`; tolerate a bare array too in
    // case the envelope is ever flattened.
    final List<dynamic> rows = fbDecoded is Map<String, dynamic>
        ? (fbDecoded['feedback'] as List<dynamic>? ?? const [])
        : (fbDecoded as List<dynamic>);
    final feedback = rows
        .whereType<Map<String, dynamic>>()
        .map(FeedbackItem.fromJson)
        .toList(growable: false);

    return AdminDashboardData(stats: stats, feedback: feedback);
  }

  /// Re-fetch stats and feedback. The screen exposes this on a refresh
  /// button; we flip back into a loading state so the spinner reappears.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// Permanently delete one feedback report (`DELETE /api/admin/feedback/{id}`)
  /// and drop it from the in-memory list without a full reload, so the row
  /// vanishes instantly. The `feedback_open` headline stat is decremented
  /// locally when the removed row was open. Throws on a non-2xx response so
  /// the caller can surface a toast.
  Future<void> deleteFeedback(String id) async {
    final serverUrl = ref.read(serverUrlProvider);
    final auth = ref.read(authProvider.notifier);

    final res = await auth.authenticatedRequest(
      (token) => http.delete(
        Uri.parse('$serverUrl/api/admin/feedback/$id'),
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw _AdminHttpError(
        'Failed to delete feedback (HTTP ${res.statusCode})',
        res.statusCode,
      );
    }

    final current = state.valueOrNull;
    if (current == null) return;
    final removed = current.feedback.where((f) => f.id == id).firstOrNull;
    final remaining = current.feedback
        .where((f) => f.id != id)
        .toList(growable: false);
    final newOpen = removed?.status == 'open'
        ? (current.stats.feedbackOpen - 1).clamp(0, 1 << 31)
        : current.stats.feedbackOpen;
    state = AsyncValue.data(
      AdminDashboardData(
        stats: current.stats.copyWith(feedbackOpen: newOpen),
        feedback: remaining,
      ),
    );
  }
}

class _AdminHttpError implements Exception {
  final String message;
  final int statusCode;
  const _AdminHttpError(this.message, this.statusCode);

  @override
  String toString() => message;
}
