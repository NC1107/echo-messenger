import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'auth_provider.dart';
import 'server_url_provider.dart';

part 'media_ticket_provider.g.dart';

/// Provides a reusable media ticket for authenticating web `<img>` requests.
///
/// The ticket is fetched once after login and refreshed every 4 minutes
/// (server TTL is 5 minutes).  On native platforms the Authorization header
/// is used instead, so this provider is only consumed on web.
///
/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Singleton lifetime via `keepAlive: true` because the refresh timer must
/// survive moments when no widget is watching the ticket.
@Riverpod(keepAlive: true)
class MediaTicket extends _$MediaTicket {
  Timer? _refreshTimer;

  @override
  String? build() {
    // Cancel the refresh timer when the provider is disposed (provider
    // lifecycle ties the timer to the notifier's lifetime cleanly).
    ref.onDispose(() {
      _refreshTimer?.cancel();
    });

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.isLoggedIn && next.token != null) {
        _fetch();
      } else {
        _clear();
      }
    });

    // Fetch immediately if already logged in.
    final auth = ref.read(authProvider);
    if (auth.isLoggedIn && auth.token != null) {
      _fetch();
    }

    return null;
  }

  Future<void> _fetch() async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (serverUrl.isEmpty || token == null) return;

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/media/ticket'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final match = RegExp(
          r'"ticket"\s*:\s*"([^"]+)"',
        ).firstMatch(response.body);
        if (match != null) {
          state = match.group(1);
          _scheduleRefresh();
        }
      }
    } catch (_) {
      // Ticket fetch failed -- media will fall back to native auth headers.
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    // Refresh 1 minute before the 5-minute server TTL expires.
    _refreshTimer = Timer(const Duration(minutes: 4), _fetch);
  }

  void _clear() {
    _refreshTimer?.cancel();
    state = null;
  }
}

/// Alias preserving the legacy `mediaTicketProvider` symbol for existing
/// call sites; codegen produces `mediaTicketProvider` directly here so the
/// alias is purely defensive against future renames.
// (No alias needed -- generated provider name matches.)
