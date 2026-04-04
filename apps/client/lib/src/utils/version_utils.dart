import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Fetches version info from the server and (on web) the web container.
/// Returns a map with keys: serverVersion, serverHost, webVersion.
Future<Map<String, String?>> fetchVersionInfo(String serverUrl) async {
  String? serverVersion;
  String? serverHost;
  String? webVersion;

  // Fetch server version from /api/health
  try {
    final uri = Uri.parse('$serverUrl/api/health');
    serverHost = uri.host;
    final resp = await http.get(uri).timeout(const Duration(seconds: 5));
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      serverVersion = body['version'] as String?;
    }
  } catch (_) {
    // serverVersion stays null
  }

  // Fetch web container version (web only)
  if (kIsWeb) {
    try {
      final resp = await http
          .get(Uri.parse('/version.txt'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final text = resp.body.trim();
        if (text.isNotEmpty && text.length < 30) {
          webVersion = text;
        }
      }
    } catch (_) {
      // webVersion stays null
    }
  }

  return {
    'serverVersion': serverVersion,
    'serverHost': serverHost,
    'webVersion': webVersion,
  };
}
