import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../providers/auth_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class DevicesSection extends ConsumerStatefulWidget {
  const DevicesSection({super.key});

  @override
  ConsumerState<DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends ConsumerState<DevicesSection> {
  List<_Device> _devices = [];
  bool _loading = true;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _deviceRevokedSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDevices();
      // Refresh when any device_revoked event arrives for another device.
      final ws = ref.read(websocketProvider.notifier);
      _deviceRevokedSub = ws.deviceRevokedEvents.listen((event) {
        final revokedId = event['device_id'];
        final myDeviceId = ref.read(cryptoServiceProvider).isInitialized
            ? ref.read(cryptoServiceProvider).deviceId
            : null;
        // Coalesce rapid bursts (e.g. revoke-others emits N events) into a
        // single refresh -- skip if we're already reloading.
        if (revokedId is int &&
            revokedId != myDeviceId &&
            mounted &&
            !_loading) {
          _loadDevices();
        }
      });
    });
  }

  @override
  void dispose() {
    _deviceRevokedSub?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final serverUrl = ref.read(serverUrlProvider);
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;

    try {
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

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        // New shape: { user_id, devices: [{device_id, platform, last_seen}] }
        // Old shape (backward compat): { user_id, device_ids: [<int>] } or a
        // bare list of device_id integers.
        final List<dynamic> rawDevices;
        if (body is List) {
          rawDevices = body;
        } else if (body is Map<String, dynamic>) {
          rawDevices =
              (body['devices'] as List<dynamic>?) ??
              (body['device_ids'] as List<dynamic>?) ??
              [];
        } else {
          rawDevices = [];
        }
        setState(() {
          _devices = rawDevices.map((d) {
            if (d is Map<String, dynamic>) {
              return _Device(
                deviceId: (d['device_id'] as num).toInt(),
                platform: d['platform'] as String?,
                lastSeen: d['last_seen'] as String?,
              );
            }
            // Legacy: bare device_id integer
            return _Device(deviceId: (d as num).toInt());
          }).toList();
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load devices (${response.statusCode})';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Network error: $e';
        _loading = false;
      });
    }
  }

  Future<void> _revokeDevice(_Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Revoke ${device.displayLabel}',
          style: const TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will remove ${device.displayLabel} from your account. '
          'Any active session on that device will be signed out immediately.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/keys/device/${device.deviceId}'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );

      if (response.statusCode == 204) {
        if (mounted) {
          ToastService.show(context, 'Device revoked');
        }
        await _loadDevices();
      } else {
        if (mounted) {
          ToastService.show(
            context,
            'Failed to revoke device (${response.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(context, 'Network error', type: ToastType.error);
      }
    }
  }

  /// Revoke every device except the current one after confirming with the user.
  Future<void> _revokeOtherDevices(int currentDeviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Log out all other devices',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will log out every device except this one. Continue?',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Log out others'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/keys/devices/revoke-others'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'current_device_id': currentDeviceId}),
            ),
          );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final count = (body['revoked'] as num?)?.toInt() ?? 0;
        if (mounted) {
          ToastService.show(
            context,
            count == 1
                ? 'Logged out 1 other device'
                : 'Logged out $count other devices',
          );
        }
        await _loadDevices();
      } else {
        if (mounted) {
          ToastService.show(
            context,
            'Failed to log out other devices (${response.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(context, 'Network error', type: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myDeviceId = ref.watch(cryptoServiceProvider).isInitialized
        ? ref.watch(cryptoServiceProvider).deviceId
        : null;

    return ListView(
      shrinkWrap: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Devices',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Manage devices that have access to your account.',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh, color: context.textSecondary),
                tooltip: 'Refresh',
                onPressed: _loading ? null : _loadDevices,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loadDevices,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          )
        else if (_devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                'No devices found.',
                style: TextStyle(color: context.textSecondary, fontSize: 14),
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final device = _devices[index];
              final isThisDevice = device.deviceId == myDeviceId;
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      _deviceIcon(isThisDevice),
                      color: isThisDevice
                          ? context.accent
                          : context.textSecondary,
                    ),
                    if (isThisDevice)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: EchoTheme.online,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: context.surface,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                title: Row(
                  children: [
                    Text(
                      isThisDevice
                          ? _currentPlatformName()
                          : device.displayLabel,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                    if (isThisDevice) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: context.accentLight,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'This device',
                          style: TextStyle(
                            color: context.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  'Last seen: ${_formatLastSeen(device.lastSeen)}',
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
                trailing: isThisDevice
                    ? null
                    : OutlinedButton.icon(
                        onPressed: () => _revokeDevice(device),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: EchoTheme.danger,
                          side: const BorderSide(color: EchoTheme.danger),
                        ),
                        icon: const Icon(Icons.remove_circle_outline, size: 16),
                        label: const Text('Revoke'),
                      ),
              );
            },
          ),
        if (!_loading &&
            _error == null &&
            myDeviceId != null &&
            _devices.any((d) => d.deviceId != myDeviceId))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _revokeOtherDevices(myDeviceId),
                icon: const Icon(Icons.devices_other, size: 18),
                label: const Text('Log out all other devices'),
                style: TextButton.styleFrom(foregroundColor: EchoTheme.danger),
              ),
            ),
          ),
      ],
    );
  }
}

class _Device {
  final int deviceId;
  final String? platform;
  final String? lastSeen;

  const _Device({required this.deviceId, this.platform, this.lastSeen});

  /// Best-effort display label. Falls back to a device-id-specific label when
  /// the server has no platform string stored (e.g. older clients) so that
  /// multiple unknown devices remain distinguishable in the list.
  String get displayLabel => platform ?? 'Device $deviceId';
}

String _formatLastSeen(String? isoString) {
  if (isoString == null) return 'Never';
  try {
    final dt = DateTime.parse(isoString).toLocal();
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m ${m == 1 ? 'minute' : 'minutes'} ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h ${h == 1 ? 'hour' : 'hours'} ago';
    }
    final d = diff.inDays;
    return '$d ${d == 1 ? 'day' : 'days'} ago';
  } catch (_) {
    return isoString;
  }
}

String _currentPlatformName() {
  if (kIsWeb) return 'Web Browser';
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return 'Unknown';
}

IconData _deviceIcon(bool isThisDevice) {
  if (!isThisDevice) return Icons.devices;
  if (kIsWeb) return Icons.language;
  if (Platform.isIOS || Platform.isAndroid) return Icons.phone_iphone;
  if (Platform.isMacOS) return Icons.laptop_mac;
  if (Platform.isWindows || Platform.isLinux) return Icons.computer;
  return Icons.devices;
}
