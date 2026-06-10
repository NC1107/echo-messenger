import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../providers/auth_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/device_name_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/settings_panel_scaffold.dart';

class DevicesSection extends ConsumerStatefulWidget {
  const DevicesSection({super.key});

  @override
  ConsumerState<DevicesSection> createState() => _DevicesSectionState();
}

/// Editable device names accept 1..=40 chars (matches server validation).
const int _kDeviceNameMaxLength = 40;

/// Visible-for-testing: client-side mirror of the server's `validate_device_name`.
/// Returns null on success or a human-readable error message; the UI surfaces
/// the message inline below the rename field.
@visibleForTesting
String? validateDeviceNameInput(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'Name cannot be empty';
  if (trimmed.length > _kDeviceNameMaxLength) {
    return 'Name too long (max $_kDeviceNameMaxLength characters)';
  }
  if (trimmed.runes.any((r) {
    final c = String.fromCharCode(r);
    return c.codeUnitAt(0) < 0x20;
  })) {
    return 'Name cannot contain control characters';
  }
  return null;
}

class _DevicesSectionState extends ConsumerState<DevicesSection> {
  List<_Device> _devices = [];
  bool _loading = true;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _deviceRevokedSub;

  /// device_id currently being edited inline, or null when no row is active.
  int? _renamingDeviceId;
  String? _renameLocalError;

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
                deviceName: d['device_name'] as String?,
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
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Revoke ${device.displayLabel}',
      content:
          'This will remove ${device.displayLabel} from your account. '
          'Any active session on that device will be signed out immediately.',
      confirmLabel: 'Revoke',
      destructive: true,
    );

    if (!confirmed) return;

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
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Log out all other devices',
      content: 'This will log out every device except this one. Continue?',
      confirmLabel: 'Log out others',
      destructive: true,
    );

    if (!confirmed) return;

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

  /// Optimistically apply the new name to the local list + the shared
  /// device-names provider, then PATCH the server. On failure restore the
  /// previous name in both places and surface a toast.
  Future<void> _submitRename(_Device device, String rawName) async {
    final validationError = validateDeviceNameInput(rawName);
    if (validationError != null) {
      setState(() {
        _renameLocalError = validationError;
      });
      return;
    }
    final normalized = rawName.trim();
    final previousName = device.deviceName;

    setState(() {
      _devices = _devices
          .map(
            (d) => d.deviceId == device.deviceId
                ? d.copyWith(deviceName: normalized)
                : d,
          )
          .toList();
      _renamingDeviceId = null;
      _renameLocalError = null;
    });

    final namesNotifier = ref.read(deviceNamesProvider.notifier);
    namesNotifier.setLocal(device.deviceId, normalized);

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.patch(
              Uri.parse('$serverUrl/api/keys/device/${device.deviceId}'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'device_name': normalized}),
            ),
          );

      if (response.statusCode == 200) {
        // Re-pull so the provider reflects the canonical server state.
        await namesNotifier.refresh();
        if (mounted) {
          ToastService.show(context, 'Device renamed');
        }
        return;
      }
      _revertRename(device.deviceId, previousName);
      if (mounted) {
        ToastService.show(
          context,
          'Failed to rename device (${response.statusCode})',
          type: ToastType.error,
        );
      }
    } catch (_) {
      _revertRename(device.deviceId, previousName);
      if (mounted) {
        ToastService.show(context, 'Network error', type: ToastType.error);
      }
    }
  }

  void _revertRename(int deviceId, String? previousName) {
    if (!mounted) return;
    setState(() {
      _devices = _devices
          .map(
            (d) => d.deviceId == deviceId
                ? d.copyWith(deviceName: previousName)
                : d,
          )
          .toList();
    });
    if (previousName != null) {
      ref.read(deviceNamesProvider.notifier).setLocal(deviceId, previousName);
    }
  }

  Widget _buildDeviceListBody(BuildContext context, int? myDeviceId) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: CenteredLoadingIndicator(),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: TextStyle(color: context.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadDevices, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text(
            'No devices found.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _devices.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final device = _devices[index];
        final isThisDevice = device.deviceId == myDeviceId;
        return _buildDeviceTile(context, device, isThisDevice);
      },
    );
  }

  Widget _buildDeviceTile(
    BuildContext context,
    _Device device,
    bool isThisDevice,
  ) {
    final isRenaming = _renamingDeviceId == device.deviceId;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: _buildDeviceLeading(context, isThisDevice),
      title: isRenaming
          ? _buildRenameField(context, device)
          : _buildDeviceTitleRow(context, device, isThisDevice),
      subtitle: Text(
        'Last seen: ${_formatLastSeen(device.lastSeen)}',
        style: TextStyle(color: context.textSecondary, fontSize: 13),
      ),
      trailing: isRenaming ? null : _buildTrailing(device, isThisDevice),
    );
  }

  Widget _buildDeviceLeading(BuildContext context, bool isThisDevice) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          _deviceIcon(isThisDevice),
          color: isThisDevice ? context.accent : context.textSecondary,
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
                border: Border.all(color: context.surface, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDeviceTitleRow(
    BuildContext context,
    _Device device,
    bool isThisDevice,
  ) {
    final label = device.deviceName?.trim().isNotEmpty == true
        ? device.deviceName!.trim()
        : (isThisDevice ? _currentPlatformName() : device.displayLabel);
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.textPrimary,
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: Key('rename-device-${device.deviceId}'),
          tooltip: 'Rename device',
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: Icon(Icons.edit, color: context.textSecondary),
          onPressed: () => setState(() {
            _renamingDeviceId = device.deviceId;
            _renameLocalError = null;
          }),
        ),
      ],
    );
  }

  Widget _buildRenameField(BuildContext context, _Device device) {
    final controller = TextEditingController(
      text: device.deviceName ?? device.displayLabel,
    );
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: Key('rename-device-field-${device.deviceId}'),
            controller: controller,
            autofocus: true,
            maxLength: _kDeviceNameMaxLength,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              errorText: _renameLocalError,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => _submitRename(device, value),
          ),
        ),
        IconButton(
          key: Key('rename-device-save-${device.deviceId}'),
          icon: Icon(Icons.check, color: context.accent),
          tooltip: 'Save',
          onPressed: () => _submitRename(device, controller.text),
        ),
        IconButton(
          icon: Icon(Icons.close, color: context.textSecondary),
          tooltip: 'Cancel',
          onPressed: () => setState(() {
            _renamingDeviceId = null;
            _renameLocalError = null;
          }),
        ),
      ],
    );
  }

  Widget? _buildTrailing(_Device device, bool isThisDevice) {
    if (isThisDevice) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: context.accentLight.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '(this device)',
          style: TextStyle(color: context.textSecondary, fontSize: 11),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => _revokeDevice(device),
      style: OutlinedButton.styleFrom(
        foregroundColor: EchoTheme.danger,
        side: const BorderSide(color: EchoTheme.danger),
      ),
      icon: const Icon(Icons.remove_circle_outline, size: 16),
      label: const Text('Revoke'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myDeviceId = ref.watch(cryptoServiceProvider).isInitialized
        ? ref.watch(cryptoServiceProvider).deviceId
        : null;

    return SettingsPanelScaffold(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Devices',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 18,
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
            ),
            IconButton(
              icon: Icon(Icons.refresh, color: context.textSecondary),
              tooltip: 'Refresh',
              onPressed: _loading ? null : _loadDevices,
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        _buildDeviceListBody(context, myDeviceId),
        if (!_loading &&
            _error == null &&
            myDeviceId != null &&
            _devices.any((d) => d.deviceId != myDeviceId))
          Padding(
            padding: const EdgeInsets.only(top: 16),
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
  final String? deviceName;

  const _Device({
    required this.deviceId,
    this.platform,
    this.lastSeen,
    this.deviceName,
  });

  _Device copyWith({String? deviceName}) => _Device(
    deviceId: deviceId,
    platform: platform,
    lastSeen: lastSeen,
    deviceName: deviceName ?? this.deviceName,
  );

  /// Best-effort display label. Prefers the editable device_name (set by the
  /// owner via PATCH /api/keys/device/:id, or seeded server-side from the
  /// platform hint), then falls back to the raw platform string, then to a
  /// device-id-specific label so multiple unknown devices remain
  /// distinguishable in the list.
  String get displayLabel => deviceName?.trim().isNotEmpty == true
      ? deviceName!.trim()
      : (platform ?? 'Device $deviceId');
}

String _formatLastSeen(String? isoString) {
  if (isoString == null) return 'Never';
  try {
    return formatRelativeTimeLong(DateTime.parse(isoString).toLocal());
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
