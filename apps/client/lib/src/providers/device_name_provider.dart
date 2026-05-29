import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_provider.dart';
import 'server_url_provider.dart';

/// In-memory cache of the authenticated user's device names, keyed by
/// `device_id`. The map is populated lazily by [deviceNamesProvider] on the
/// first read and refreshed when a caller invokes
/// [DeviceNamesNotifier.refresh] (for example after a successful rename so
/// every downstream consumer — including the multi-device authority pill —
/// picks up the new value without a page reload).
///
/// See `docs/voice-lounge/03-multi-device.md` — Option C decision: the pill
/// labels the device holding the canvas write lock, which means we need a
/// device_id → display-name map even when the device is offline.
class DeviceNamesNotifier extends AsyncNotifier<Map<int, String>> {
  @override
  Future<Map<int, String>> build() {
    return _fetch();
  }

  /// Refetch from the server. Used after a rename so consumers see the new
  /// label immediately.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_fetch);
  }

  /// Optimistic local update. Inserted/overwritten in the current map so the
  /// UI updates before the server round-trip completes; callers must restore
  /// the old value (via [setLocal]) on PATCH failure.
  void setLocal(int deviceId, String name) {
    final current = state.valueOrNull ?? const <int, String>{};
    state = AsyncValue.data({...current, deviceId: name});
  }

  Future<Map<int, String>> _fetch() async {
    final serverUrl = ref.read(serverUrlProvider);
    final userId = ref.read(authProvider).userId;
    if (userId == null) return const <int, String>{};

    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.get(
            Uri.parse('$serverUrl/api/keys/devices/$userId'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ),
        );

    if (response.statusCode != 200) {
      return const <int, String>{};
    }

    final body = jsonDecode(response.body);
    final List<dynamic> rawDevices;
    if (body is List) {
      rawDevices = body;
    } else if (body is Map<String, dynamic>) {
      rawDevices = (body['devices'] as List<dynamic>?) ?? const [];
    } else {
      rawDevices = const [];
    }

    final result = <int, String>{};
    for (final raw in rawDevices) {
      if (raw is! Map<String, dynamic>) continue;
      final id = (raw['device_id'] as num?)?.toInt();
      if (id == null) continue;
      final name = raw['device_name'] as String?;
      if (name != null && name.trim().isNotEmpty) {
        result[id] = name;
        continue;
      }
      // Backward-compat fallback when the server hasn't been migrated yet:
      // fall back to `platform` then `Device $id` so the pill still has
      // something to show.
      final platform = raw['platform'] as String?;
      if (platform != null && platform.trim().isNotEmpty) {
        result[id] = platform;
      } else {
        result[id] = 'Device $id';
      }
    }
    return result;
  }
}

/// Cached map of `device_id -> device_name` for the authenticated user.
final deviceNamesProvider =
    AsyncNotifierProvider<DeviceNamesNotifier, Map<int, String>>(
      DeviceNamesNotifier.new,
    );

/// Convenience selector: the display name for [deviceId], or null when the
/// map hasn't loaded yet or the device is not registered.
final deviceNameProvider = Provider.family<String?, int>((ref, deviceId) {
  final names = ref.watch(deviceNamesProvider);
  return names.maybeWhen(data: (map) => map[deviceId], orElse: () => null);
});
