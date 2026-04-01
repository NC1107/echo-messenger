import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Default server URL for production deployment.
const defaultServerUrl = 'https://echo-messenger.us';

/// SharedPreferences key for the user-configured server URL.
const _prefsKeyServerUrl = 'echo_server_url';

/// Riverpod provider that holds the current server URL.
///
/// All providers and services that need the server URL should read from this
/// single source of truth. The URL can be changed at runtime via the settings
/// screen and is persisted in SharedPreferences.
final serverUrlProvider = StateNotifierProvider<ServerUrlNotifier, String>((
  ref,
) {
  return ServerUrlNotifier();
});

class ServerUrlNotifier extends StateNotifier<String> {
  ServerUrlNotifier() : super(defaultServerUrl);

  /// Load the server URL from SharedPreferences.
  /// Falls back to [defaultServerUrl] if nothing is stored.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKeyServerUrl);
    if (stored != null && stored.isNotEmpty) {
      state = stored;
    }
  }

  /// Update the server URL and persist to SharedPreferences.
  Future<void> setUrl(String url) async {
    // Normalize: remove trailing slash
    final normalized = url.endsWith('/')
        ? url.substring(0, url.length - 1)
        : url;
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
}

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
