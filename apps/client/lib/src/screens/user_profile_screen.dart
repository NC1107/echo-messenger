import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart' show buildAvatar;

/// Shows a user profile. On desktop (>=900px) opens as a dialog; on mobile as
/// a full screen page.
class UserProfileScreen extends ConsumerStatefulWidget {
  final String userId;

  const UserProfileScreen({super.key, required this.userId});

  /// Open the profile as a dialog on desktop or push a full-screen route on
  /// mobile.
  static void show(BuildContext context, WidgetRef ref, String userId) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: 400,
            height: 500,
            child: UserProfileScreen(userId: userId),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: const Text('Profile'),
              backgroundColor: context.surface,
            ),
            body: UserProfileScreen(userId: userId),
          ),
        ),
      );
    }
  }

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  bool _isLoading = true;
  String? _error;

  String _username = '';
  String? _displayName;
  String? _bio;
  String? _avatarUrl;
  String? _createdAt;
  String? _statusMessage;
  String? _pronouns;
  String? _timezone;
  String? _website;
  String? _email;
  String? _phone;
  bool _isContact = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProfile());
  }

  Future<void> _loadProfile() async {
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/users/${widget.userId}/profile'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _username = data['username'] as String? ?? '';
          _displayName = data['display_name'] as String?;
          _bio = data['bio'] as String?;
          _avatarUrl = data['avatar_url'] as String?;
          _createdAt = data['created_at'] as String?;
          _statusMessage = data['status_message'] as String?;
          _pronouns = data['pronouns'] as String?;
          _timezone = data['timezone'] as String?;
          _website = data['website'] as String?;
          _email = data['email'] as String?;
          _phone = data['phone'] as String?;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load profile (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load profile';
          _isLoading = false;
        });
      }
    }

    // Check if user is already a contact
    final contacts = ref.read(contactsProvider).contacts;
    if (contacts.any((c) => c.userId == widget.userId)) {
      if (mounted) setState(() => _isContact = true);
    }
  }

  Future<void> _addContact() async {
    if (_username.isEmpty) return;
    await ref.read(contactsProvider.notifier).sendRequest(_username);
    if (mounted) {
      ToastService.show(
        context,
        'Contact request sent',
        type: ToastType.success,
      );
    }
  }

  /// Compute the current local time string for an IANA timezone name.
  /// Uses a hardcoded offset map for common timezones; falls back to
  /// the device's local offset when the zone is unknown.
  String _formatLocalTime(String iana) {
    final offset = _ianaOffsetMinutes[iana];
    final now = DateTime.now().toUtc();
    final local = offset != null
        ? now.add(Duration(minutes: offset))
        : now.add(DateTime.now().timeZoneOffset);

    final hour24 = local.hour;
    final minute = local.minute;
    final isPm = hour24 >= 12;
    final int hour12;
    if (hour24 == 0) {
      hour12 = 12;
    } else if (hour24 > 12) {
      hour12 = hour24 - 12;
    } else {
      hour12 = hour24;
    }
    final minuteStr = minute.toString().padLeft(2, '0');
    final period = isPm ? 'PM' : 'AM';
    return '$hour12:$minuteStr $period';
  }

  /// Common IANA timezone -> UTC offset in minutes.
  /// Covers major world timezones. DST is approximated for standard offset;
  /// for perfect DST handling a full tz database would be needed.
  static const _ianaOffsetMinutes = <String, int>{
    // UTC / GMT
    'UTC': 0,
    'GMT': 0,
    'Etc/UTC': 0,
    'Etc/GMT': 0,
    // North America
    'America/New_York': -300,
    'America/Toronto': -300,
    'America/Detroit': -300,
    'America/Chicago': -360,
    'America/Winnipeg': -360,
    'America/Denver': -420,
    'America/Edmonton': -420,
    'America/Phoenix': -420,
    'America/Los_Angeles': -480,
    'America/Vancouver': -480,
    'America/Anchorage': -540,
    'Pacific/Honolulu': -600,
    'America/Halifax': -240,
    'America/St_Johns': -210,
    // Central / South America
    'America/Mexico_City': -360,
    'America/Bogota': -300,
    'America/Lima': -300,
    'America/Santiago': -240,
    'America/Sao_Paulo': -180,
    'America/Argentina/Buenos_Aires': -180,
    'America/Caracas': -240,
    // Europe
    'Europe/London': 0,
    'Europe/Dublin': 0,
    'Europe/Lisbon': 0,
    'Europe/Paris': 60,
    'Europe/Berlin': 60,
    'Europe/Amsterdam': 60,
    'Europe/Brussels': 60,
    'Europe/Madrid': 60,
    'Europe/Rome': 60,
    'Europe/Vienna': 60,
    'Europe/Zurich': 60,
    'Europe/Stockholm': 60,
    'Europe/Oslo': 60,
    'Europe/Copenhagen': 60,
    'Europe/Warsaw': 60,
    'Europe/Prague': 60,
    'Europe/Budapest': 60,
    'Europe/Helsinki': 120,
    'Europe/Bucharest': 120,
    'Europe/Athens': 120,
    'Europe/Istanbul': 180,
    'Europe/Moscow': 180,
    'Europe/Kiev': 120,
    'Europe/Kyiv': 120,
    // Africa
    'Africa/Cairo': 120,
    'Africa/Lagos': 60,
    'Africa/Johannesburg': 120,
    'Africa/Nairobi': 180,
    'Africa/Casablanca': 60,
    // Middle East
    'Asia/Dubai': 240,
    'Asia/Riyadh': 180,
    'Asia/Tehran': 210,
    'Asia/Jerusalem': 120,
    // South / Southeast Asia
    'Asia/Kolkata': 330,
    'Asia/Colombo': 330,
    'Asia/Dhaka': 360,
    'Asia/Karachi': 300,
    'Asia/Bangkok': 420,
    'Asia/Jakarta': 420,
    'Asia/Ho_Chi_Minh': 420,
    'Asia/Singapore': 480,
    'Asia/Kuala_Lumpur': 480,
    'Asia/Manila': 480,
    // East Asia
    'Asia/Shanghai': 480,
    'Asia/Hong_Kong': 480,
    'Asia/Taipei': 480,
    'Asia/Seoul': 540,
    'Asia/Tokyo': 540,
    // Oceania
    'Australia/Sydney': 600,
    'Australia/Melbourne': 600,
    'Australia/Brisbane': 600,
    'Australia/Perth': 480,
    'Australia/Adelaide': 570,
    'Australia/Darwin': 570,
    'Pacific/Auckland': 720,
    'Pacific/Fiji': 720,
    'Pacific/Guam': 600,
  };

  String _formatMemberSince(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.watch(serverUrlProvider);

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
      );
    }

    final fullAvatarUrl = _avatarUrl != null ? '$serverUrl$_avatarUrl' : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          buildAvatar(name: _username, radius: 40, imageUrl: fullAvatarUrl),
          const SizedBox(height: 16),
          _buildNameSection(),
          _buildStatusSection(),
          const SizedBox(height: 12),
          _buildBioSection(),
          ..._buildContactDetailRows(),
          _buildMemberSinceRow(),
          const SizedBox(height: 28),
          _buildActionButton(),
        ],
      ),
    );
  }

  /// Display name + username + pronouns header section.
  Widget _buildNameSection() {
    return Column(
      children: [
        if (_displayName != null && _displayName!.isNotEmpty)
          Text(
            _displayName!,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '@$_username',
              style: TextStyle(
                color: _displayName != null
                    ? context.textMuted
                    : context.textPrimary,
                fontSize: _displayName != null ? 14 : 22,
                fontWeight: _displayName != null
                    ? FontWeight.normal
                    : FontWeight.bold,
              ),
            ),
            if (_pronouns != null && _pronouns!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                _pronouns!,
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Status message line (if set).
  Widget _buildStatusSection() {
    if (_statusMessage == null || _statusMessage!.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        _statusMessage!,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 13,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  /// Bio paragraph (if set).
  Widget _buildBioSection() {
    if (_bio == null || _bio!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          _bio!,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  /// Build icon+label rows for website, email, phone, and timezone.
  List<Widget> _buildContactDetailRows() {
    return [
      if (_website != null && _website!.isNotEmpty) ...[
        _iconRow(
          icon: Icons.link,
          iconColor: context.accent,
          text: _website!,
          textColor: context.accent,
          underline: true,
        ),
        const SizedBox(height: 8),
      ],
      if (_email != null && _email!.isNotEmpty) ...[
        _iconRow(
          icon: Icons.email_outlined,
          iconColor: context.textMuted,
          text: _email!,
          textColor: context.textMuted,
        ),
        const SizedBox(height: 8),
      ],
      if (_phone != null && _phone!.isNotEmpty) ...[
        _iconRow(
          icon: Icons.phone_outlined,
          iconColor: context.textMuted,
          text: _phone!,
          textColor: context.textMuted,
        ),
        const SizedBox(height: 8),
      ],
      if (_timezone != null && _timezone!.isNotEmpty) ...[
        _iconRow(
          icon: Icons.schedule,
          iconColor: context.textMuted,
          text: 'Local time: ${_formatLocalTime(_timezone!)} ($_timezone)',
          textColor: context.textMuted,
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget _iconRow({
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color textColor,
    bool underline = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: textColor,
            fontSize: 13,
            decoration: underline ? TextDecoration.underline : null,
            decorationColor: underline ? textColor : null,
          ),
        ),
      ],
    );
  }

  /// "Member since" row.
  Widget _buildMemberSinceRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.calendar_today_outlined, size: 14, color: context.textMuted),
        const SizedBox(width: 6),
        Text(
          'Member since ${_formatMemberSince(_createdAt)}',
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
      ],
    );
  }

  /// Add contact / already contact action button.
  Widget _buildActionButton() {
    if (!_isContact && widget.userId != ref.read(authProvider).userId) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _addContact,
          icon: const Icon(Icons.person_add_outlined, size: 18),
          label: const Text('Add Contact'),
          style: FilledButton.styleFrom(
            backgroundColor: context.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
    }
    if (_isContact) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Contact'),
          style: FilledButton.styleFrom(
            backgroundColor: EchoTheme.online,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
