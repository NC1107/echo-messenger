import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../providers/auth_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/server_url_provider.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
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
        final list = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _devices = list
              .map(
                (d) => _Device(
                  deviceId: (d['device_id'] as num).toInt(),
                  label: d['label'] as String? ?? 'Device',
                  lastSeen: d['last_seen'] as String?,
                ),
              )
              .toList();
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
          'Revoke ${device.label}',
          style: const TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will remove ${device.label} from your account. '
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

  @override
  Widget build(BuildContext context) {
    final myDeviceId = ref.watch(cryptoServiceProvider).isInitialized
        ? ref.watch(cryptoServiceProvider).deviceId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Expanded(
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
          Expanded(
            child: Center(
              child: Text(
                'No devices found.',
                style: TextStyle(color: context.textSecondary, fontSize: 14),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
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
                  leading: Icon(
                    Icons.devices,
                    color: isThisDevice
                        ? context.accent
                        : context.textSecondary,
                  ),
                  title: Row(
                    children: [
                      Text(
                        device.label,
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
                  subtitle: device.lastSeen != null
                      ? Text(
                          'Last seen: ${device.lastSeen}',
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 12,
                          ),
                        )
                      : null,
                  trailing: isThisDevice
                      ? null
                      : TextButton(
                          onPressed: () => _revokeDevice(device),
                          style: TextButton.styleFrom(
                            foregroundColor: EchoTheme.danger,
                          ),
                          child: const Text('Revoke'),
                        ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Device {
  final int deviceId;
  final String label;
  final String? lastSeen;

  const _Device({required this.deviceId, required this.label, this.lastSeen});
}
