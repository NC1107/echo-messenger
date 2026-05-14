import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of a successful YouTube oEmbed lookup.
///
/// The oEmbed endpoint returns more fields (thumbnail, html, width/height)
/// but we only surface what we actually use in the chat embed.
class YouTubeOEmbedData {
  final String title;
  final String? authorName;

  const YouTubeOEmbedData({required this.title, this.authorName});
}

/// Fetches YouTube video titles via the public oEmbed endpoint
/// (`https://www.youtube.com/oembed?...&format=json`).
///
/// No API key required. Results are cached in-memory per video id so
/// re-renders of the same message do not hit the network. Failures are
/// not cached -- they fall through to the no-title state and can retry.
class YouTubeOEmbedService {
  static const String _endpoint = 'https://www.youtube.com/oembed';
  static const int _maxCacheSize = 200;
  static const Duration _timeout = Duration(seconds: 5);

  /// In-memory cache keyed by 11-char video id. Static so the lifetime
  /// matches the app session and we never refetch the same title twice.
  static final Map<String, YouTubeOEmbedData> _cache = {};

  /// Outstanding fetches keyed by video id so two embeds for the same
  /// video on screen at once share a single network round-trip.
  static final Map<String, Future<YouTubeOEmbedData?>> _inflight = {};

  final http.Client _client;

  /// [client] is injectable so tests can swap in a mocktail client.
  /// When omitted, a fresh [http.Client] is created per service instance
  /// (cheap on every platform; oEmbed is plain HTTPS, no cookies needed).
  YouTubeOEmbedService({http.Client? client})
    : _client = client ?? http.Client();

  /// Returns cached oEmbed data for [videoId] if available, else null.
  /// Synchronous and side-effect free -- safe to call in build().
  YouTubeOEmbedData? cached(String videoId) => _cache[videoId];

  /// Fetches oEmbed metadata for [videoId]. Returns null on any failure
  /// (network error, non-2xx, malformed JSON, missing title). Successful
  /// results are cached for the rest of the session.
  Future<YouTubeOEmbedData?> fetch(String videoId) async {
    final hit = _cache[videoId];
    if (hit != null) return hit;

    final existing = _inflight[videoId];
    if (existing != null) return existing;

    final future = _fetchUncached(videoId);
    _inflight[videoId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(videoId);
    }
  }

  Future<YouTubeOEmbedData?> _fetchUncached(String videoId) async {
    try {
      final uri = Uri.parse(
        '$_endpoint?url=https://www.youtube.com/watch?v=$videoId&format=json',
      );
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;

      final title = body['title'];
      if (title is! String || title.isEmpty) return null;

      final author = body['author_name'];
      final data = YouTubeOEmbedData(
        title: title,
        authorName: author is String && author.isNotEmpty ? author : null,
      );

      // Evict oldest entry when cache is full (insertion-order map).
      if (_cache.length >= _maxCacheSize) {
        _cache.remove(_cache.keys.first);
      }
      _cache[videoId] = data;
      return data;
    } catch (_) {
      // Network error / timeout / parse failure: degrade silently to no-title.
      return null;
    }
  }

  /// Visible for testing. Clears both the cache and inflight map.
  static void debugReset() {
    _cache.clear();
    _inflight.clear();
  }
}
