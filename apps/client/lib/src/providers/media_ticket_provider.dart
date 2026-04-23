import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// Provides a reusable media ticket for authenticating web `<img>` requests.
///
/// The ticket is fetched once after login and refreshed every 4 minutes
/// (server TTL is 5 minutes).  On native platforms the Authorization header
/// is used instead, so this provider is only consumed on web.
final mediaTicketProvider = StateNotifierProvider<MediaTicketNotifier, String?>(
  (ref) {
    return MediaTicketNotifier(ref);
  },
);

class MediaTicketNotifier extends StateNotifier<String?> {
  final Ref ref;
  Timer? _refreshTimer;

  MediaTicketNotifier(this.ref) : super(null) {
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

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
