import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// The server's configured "welcome" group, surfaced once on a user's first
/// visit to the home screen so they have somewhere to land. Mirrors the slim
/// payload from `GET /api/groups/featured` (see
/// `apps/server/src/routes/groups/public.rs`).
@immutable
class FeaturedGroup {
  final String id;
  final String title;
  final String? description;
  final String? iconUrl;
  final int memberCount;

  /// Whether the requesting user is already a member — when true the client
  /// skips the welcome offer entirely.
  final bool isMember;

  const FeaturedGroup({
    required this.id,
    required this.title,
    required this.description,
    required this.iconUrl,
    required this.memberCount,
    required this.isMember,
  });

  factory FeaturedGroup.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    return FeaturedGroup(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String?,
      iconUrl: json['icon_url'] as String?,
      memberCount: asInt(json['member_count']),
      isMember: json['is_member'] as bool? ?? false,
    );
  }
}

/// Fetches the welcome group, or `null` when the server hasn't configured one
/// (HTTP 204). Any error (network, auth, malformed) also resolves to `null` —
/// the welcome offer is a nice-to-have, never a blocker on reaching home.
final featuredGroupProvider = FutureProvider.autoDispose<FeaturedGroup?>((
  ref,
) async {
  final serverUrl = ref.read(serverUrlProvider);
  final token = ref.read(authProvider).token;
  if (token == null || token.isEmpty) return null;

  try {
    final res = await http
        .get(
          Uri.parse('$serverUrl/api/groups/featured'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));

    if (res.statusCode == 204 || res.body.trim().isEmpty) return null;
    if (res.statusCode != 200) return null;

    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return null;
    final group = FeaturedGroup.fromJson(decoded);
    return group.id.isEmpty ? null : group;
  } catch (_) {
    return null;
  }
});
