/// Notification snooze state — the silence-for-a-while toggle in
/// settings + the bell-slash overlay on the sidebar avatar.
///
/// Backed by `PATCH /api/users/me/notifications/snooze` on the server.
/// The provider holds the absolute UTC "snoozed until" timestamp, or
/// `null` when not snoozed. A self-cancelling [Timer] flips the state
/// back to `null` the moment the window elapses so the UI doesn't have
/// to wait for a manual refresh.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// Allowed snooze presets surfaced in the settings UI.
enum SnoozeDuration { oneHour, eightHours, twentyFourHours, tomorrowMorning }

/// Resolve a [SnoozeDuration] to an absolute UTC "until" instant.
///
/// `tomorrowMorning` lands at 9 AM local time on the next calendar day,
/// then converts to UTC for the wire format. Exposed for tests.
DateTime resolveSnoozeUntil(SnoozeDuration duration, {DateTime? now}) {
  final base = now ?? DateTime.now();
  switch (duration) {
    case SnoozeDuration.oneHour:
      return base.toUtc().add(const Duration(hours: 1));
    case SnoozeDuration.eightHours:
      return base.toUtc().add(const Duration(hours: 8));
    case SnoozeDuration.twentyFourHours:
      return base.toUtc().add(const Duration(hours: 24));
    case SnoozeDuration.tomorrowMorning:
      final tomorrow9 = DateTime(base.year, base.month, base.day + 1, 9);
      return tomorrow9.toUtc();
  }
}

class NotificationsSnoozeNotifier extends StateNotifier<DateTime?> {
  NotificationsSnoozeNotifier(this._ref) : super(null) {
    // Best-effort initial hydration from GET /api/users/me. If the user
    // isn't logged in yet, the listener below will retry on auth change.
    unawaited(_hydrate());
    _ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.isLoggedIn && (prev?.userId != next.userId)) {
        unawaited(_hydrate());
      }
      if (!next.isLoggedIn) {
        _clearLocal();
      }
    });
  }

  final Ref _ref;
  Timer? _expiryTimer;

  Future<void> snoozeFor(SnoozeDuration duration) async {
    final until = resolveSnoozeUntil(duration);
    await snoozeUntil(until);
  }

  Future<void> snoozeUntil(DateTime when) async {
    final utc = when.toUtc();
    await _patch({'until': utc.toIso8601String()});
    _setLocal(utc);
  }

  Future<void> clear() async {
    await _patch({'until': null});
    _clearLocal();
  }

  Future<void> _patch(Map<String, dynamic> body) async {
    final authNotifier = _ref.read(authProvider.notifier);
    try {
      await authNotifier.authenticatedRequest((token) {
        final url =
            '${_ref.read(serverUrlProvider)}'
            '/api/users/me/notifications/snooze';
        return http.patch(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        );
      });
    } catch (e) {
      debugPrint('[Snooze] PATCH failed: $e');
      rethrow;
    }
  }

  Future<void> _hydrate() async {
    final authNotifier = _ref.read(authProvider.notifier);
    if (!_ref.read(authProvider).isLoggedIn) return;
    try {
      final resp = await authNotifier.authenticatedRequest(
        (token) => http.get(
          Uri.parse('${_ref.read(serverUrlProvider)}/api/users/me'),
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final raw = data['notifications_snoozed_until'] as String?;
      final parsed = raw == null ? null : DateTime.tryParse(raw)?.toUtc();
      if (parsed != null && parsed.isAfter(DateTime.now().toUtc())) {
        _setLocal(parsed);
      } else {
        _clearLocal();
      }
    } catch (e) {
      debugPrint('[Snooze] hydrate failed: $e');
    }
  }

  void _setLocal(DateTime utc) {
    state = utc;
    _expiryTimer?.cancel();
    final remaining = utc.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) {
      _clearLocal();
      return;
    }
    _expiryTimer = Timer(remaining, _clearLocal);
  }

  void _clearLocal() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (state != null) state = null;
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}

/// Watch this for the current snooze until-time (or `null` when not snoozed).
final notificationsSnoozeProvider =
    StateNotifierProvider<NotificationsSnoozeNotifier, DateTime?>(
      (ref) => NotificationsSnoozeNotifier(ref),
    );
