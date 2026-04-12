import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/accessibility_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/theme_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/echo_logo_icon.dart';

/// Shared preferences key that gates whether onboarding has been completed.
const kOnboardingCompletedKey = 'onboarding_completed';

class OnboardingWizard extends ConsumerStatefulWidget {
  const OnboardingWizard({super.key});

  @override
  ConsumerState<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends ConsumerState<OnboardingWizard> {
  final _pageController = PageController();
  int _currentPage = 0;

  // Page 1 -- Welcome
  final _displayNameController = TextEditingController();
  PlatformFile? _pickedAvatar;
  bool _uploadingAvatar = false;

  // Page 2 -- About you
  final _pronounsController = TextEditingController();
  final _bioController = TextEditingController();
  final _statusController = TextEditingController();
  final _timezoneController = TextEditingController();
  bool _customPronoun = false;

  // Page 3 -- Add contact
  final _contactUsernameController = TextEditingController();
  bool _sendingRequest = false;
  String? _contactResult;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _timezoneController.text = DateTime.now().timeZoneName;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _displayNameController.dispose();
    _pronounsController.dispose();
    _bioController.dispose();
    _statusController.dispose();
    _timezoneController.dispose();
    _contactUsernameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Navigation helpers
  // ---------------------------------------------------------------------------

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _next() {
    if (_currentPage < 3) {
      _goToPage(_currentPage + 1);
    } else {
      _finish();
    }
  }

  void _skip() => _finish();

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      await _saveProfile();
      await _markOnboardingComplete();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted) context.go('/home');
  }

  // ---------------------------------------------------------------------------
  // Profile save
  // ---------------------------------------------------------------------------

  Future<void> _saveProfile() async {
    final serverUrl = ref.read(serverUrlProvider);
    final body = <String, dynamic>{
      'display_name': _displayNameController.text,
      'bio': _bioController.text,
      'status_message': _statusController.text,
      'pronouns': _pronounsController.text,
      'timezone': _timezoneController.text,
    };

    try {
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.patch(
              Uri.parse('$serverUrl/api/users/me/profile'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            ),
          );
    } catch (e) {
      debugPrint('[Onboarding] profile save failed: $e');
    }
  }

  Future<void> _markOnboardingComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingCompletedKey, true);
  }

  // ---------------------------------------------------------------------------
  // Avatar upload
  // ---------------------------------------------------------------------------

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() => _pickedAvatar = file);
    await _uploadAvatar(file);
  }

  static MediaType _mimeFromFilename(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
      'webp' => MediaType('image', 'webp'),
      'gif' => MediaType('image', 'gif'),
      _ => MediaType('image', 'png'),
    };
  }

  Future<void> _uploadAvatar(PlatformFile file) async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (token == null) return;

    setState(() => _uploadingAvatar = true);
    try {
      final uri = Uri.parse('$serverUrl/api/users/me/avatar');
      final request = http.MultipartRequest('PUT', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(
          http.MultipartFile.fromBytes(
            'avatar',
            file.bytes!,
            filename: file.name,
            contentType: _mimeFromFilename(file.name),
          ),
        );

      final streamedResponse = await request.send();
      final body = await streamedResponse.stream.bytesToString();
      if (!mounted) return;

      if (streamedResponse.statusCode == 200) {
        try {
          final data = jsonDecode(body) as Map<String, dynamic>;
          final avatarUrl = data['avatar_url'] as String?;
          if (avatarUrl != null) {
            ref.read(authProvider.notifier).updateAvatarUrl(avatarUrl);
          }
        } catch (_) {}
        ToastService.show(context, 'Avatar uploaded', type: ToastType.success);
      } else {
        ToastService.show(
          context,
          'Avatar upload failed (${streamedResponse.statusCode})',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(context, 'Upload error: $e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Contact request
  // ---------------------------------------------------------------------------

  Future<void> _sendContactRequest() async {
    final username = _contactUsernameController.text.trim();
    if (username.isEmpty) return;

    setState(() {
      _sendingRequest = true;
      _contactResult = null;
    });

    try {
      ref.read(contactsProvider.notifier).sendRequest(username);
      if (mounted) {
        setState(() {
          _contactResult = 'Request sent to @$username';
          _sendingRequest = false;
        });
        _contactUsernameController.clear();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _contactResult = 'Failed to send request';
          _sendingRequest = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  // Logo
                  const SizedBox(height: 12),
                  const EchoLogoIcon(size: 36),
                  const SizedBox(height: 20),

                  // Pages
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const NeverScrollableScrollPhysics(),
                      onPageChanged: (i) => setState(() => _currentPage = i),
                      children: [
                        _buildWelcomePage(context),
                        _buildAboutYouPage(context),
                        _buildAppearancePage(context),
                        _buildContactPage(context),
                      ],
                    ),
                  ),

                  // Dot indicator + buttons
                  const SizedBox(height: 16),
                  _buildBottomControls(context),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page 1 -- Welcome
  // ---------------------------------------------------------------------------

  Widget _buildWelcomePage(BuildContext context) {
    final auth = ref.watch(authProvider);
    final serverUrl = ref.read(serverUrlProvider);
    final username = auth.username ?? '';

    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            'Welcome to Echo!',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Set up your profile so others can recognize you.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: context.textMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Your messages are end-to-end encrypted.',
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Avatar circle
          GestureDetector(
            onTap: _uploadingAvatar ? null : _pickAvatar,
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: context.accent, width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: context.surface,
                    backgroundImage: _avatarImage(auth, serverUrl),
                    child: _avatarChild(auth, username),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: context.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.mainBg, width: 2),
                    ),
                    child: _uploadingAvatar
                        ? const Padding(
                            padding: EdgeInsets.all(6),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.camera_alt,
                            size: 14,
                            color: Colors.white,
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap to upload a photo',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 24),

          _buildField(
            controller: _displayNameController,
            label: 'Display Name',
            hint: 'How others will see you',
            maxLength: 50,
          ),
        ],
      ),
    );
  }

  ImageProvider? _avatarImage(AuthState auth, String serverUrl) {
    // Prefer freshly-picked local bytes
    if (_pickedAvatar?.bytes != null) {
      return MemoryImage(_pickedAvatar!.bytes!);
    }
    if (auth.avatarUrl != null) {
      return NetworkImage(
        '$serverUrl${auth.avatarUrl}',
        headers: {'Authorization': 'Bearer ${auth.token}'},
      );
    }
    return null;
  }

  Widget? _avatarChild(AuthState auth, String username) {
    if (_pickedAvatar?.bytes != null || auth.avatarUrl != null) return null;
    return Icon(Icons.person, size: 40, color: context.textMuted);
  }

  // ---------------------------------------------------------------------------
  // Page 2 -- About
  // ---------------------------------------------------------------------------

  // Common pronoun options
  static const _pronounOptions = [
    'he/him',
    'she/her',
    'they/them',
    'he/they',
    'she/they',
    'any pronouns',
  ];

  // Common IANA timezones
  static const _timezones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
    'America/Toronto',
    'America/Vancouver',
    'America/Mexico_City',
    'America/Sao_Paulo',
    'America/Argentina/Buenos_Aires',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Rome',
    'Europe/Amsterdam',
    'Europe/Stockholm',
    'Europe/Moscow',
    'Europe/Istanbul',
    'Africa/Cairo',
    'Africa/Lagos',
    'Africa/Johannesburg',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Bangkok',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Asia/Singapore',
    'Australia/Sydney',
    'Australia/Melbourne',
    'Australia/Perth',
    'Pacific/Auckland',
  ];

  Widget _buildPronounsField() {
    final currentValue = _pronounsController.text;
    final isOther =
        _customPronoun ||
        (currentValue.isNotEmpty && !_pronounOptions.contains(currentValue));

    final String? dropdownInitial;
    if (isOther) {
      dropdownInitial = 'other';
    } else if (currentValue.isEmpty) {
      dropdownInitial = null;
    } else {
      dropdownInitial = currentValue;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: dropdownInitial,
          decoration: InputDecoration(
            labelText: 'Pronouns',
            labelStyle: TextStyle(color: context.textSecondary),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.accent),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          dropdownColor: context.surface,
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          items: [
            ..._pronounOptions.map(
              (p) => DropdownMenuItem(value: p, child: Text(p)),
            ),
            const DropdownMenuItem(value: 'other', child: Text('Other...')),
          ],
          onChanged: (value) {
            setState(() {
              if (value == 'other') {
                _customPronoun = true;
                _pronounsController.text = '';
              } else {
                _customPronoun = false;
                _pronounsController.text = value ?? '';
              }
            });
          },
        ),
        if (isOther) ...[
          const SizedBox(height: 8),
          _buildField(
            controller: _pronounsController,
            label: 'Custom pronouns',
            hint: 'Enter your pronouns',
            maxLength: 30,
          ),
        ],
      ],
    );
  }

  Widget _buildTimezoneDropdown() {
    final current = _timezoneController.text;
    final isInList = _timezones.contains(current);

    return DropdownButtonFormField<String>(
      initialValue: isInList ? current : null,
      decoration: InputDecoration(
        labelText: 'Timezone',
        hintText: current.isNotEmpty && !isInList ? current : 'Select timezone',
        hintStyle: TextStyle(color: context.textMuted),
        labelStyle: TextStyle(color: context.textSecondary),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      dropdownColor: context.surface,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      isExpanded: true,
      menuMaxHeight: 300,
      items: _timezones
          .map((tz) => DropdownMenuItem(value: tz, child: Text(tz)))
          .toList(),
      onChanged: (value) {
        setState(() => _timezoneController.text = value ?? '');
      },
    );
  }

  // -------------------------------------------------------------------------
  // Theme picker data for onboarding
  // -------------------------------------------------------------------------

  static const _onboardingThemes =
      <({AppThemeSelection selection, String label, Color accent, Color bg})>[
        (
          selection: AppThemeSelection.dark,
          label: 'Dark',
          accent: EchoTheme.accent,
          bg: EchoTheme.mainBg,
        ),
        (
          selection: AppThemeSelection.light,
          label: 'Light',
          accent: EchoTheme.accent,
          bg: EchoTheme.lightMainBg,
        ),
        (
          selection: AppThemeSelection.graphite,
          label: 'Graphite',
          accent: EchoTheme.graphiteAccent,
          bg: EchoTheme.graphiteMainBg,
        ),
        (
          selection: AppThemeSelection.ember,
          label: 'Ember',
          accent: EchoTheme.emberAccent,
          bg: EchoTheme.emberMainBg,
        ),
        (
          selection: AppThemeSelection.neon,
          label: 'Neon',
          accent: EchoTheme.neonAccent,
          bg: EchoTheme.neonMainBg,
        ),
        (
          selection: AppThemeSelection.sakura,
          label: 'Sakura',
          accent: EchoTheme.sakuraAccent,
          bg: EchoTheme.sakuraMainBg,
        ),
      ];

  Widget _buildAppearancePage(BuildContext context) {
    final currentTheme = ref.watch(themeProvider);

    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            'Make it yours',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pick a theme and layout.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Theme picker -- horizontal scrollable row
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: _onboardingThemes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final t = _onboardingThemes[index];
                final isSelected = currentTheme == t.selection;
                return GestureDetector(
                  onTap: () =>
                      ref.read(themeProvider.notifier).setTheme(t.selection),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: t.bg,
                          border: Border.all(
                            color: isSelected ? t.accent : context.border,
                            width: isSelected ? 2.5 : 1.5,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: t.accent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        t.label,
                        style: TextStyle(
                          color: isSelected
                              ? context.accent
                              : context.textSecondary,
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 24),

          // Message layout chips
          _buildMessageLayoutChips(),
          const SizedBox(height: 18),

          // Font size slider
          _buildFontSizeSlider(),
          const SizedBox(height: 10),

          // Accessibility toggles
          _buildAccessibilityToggles(),
        ],
      ),
    );
  }

  Widget _buildAboutYouPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            'About you',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Optional — you can always change these later in Settings.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _buildField(
            controller: _bioController,
            label: 'Bio',
            hint: 'Tell others about yourself',
            maxLength: 300,
            maxLines: 3,
          ),
          const SizedBox(height: 14),
          _buildTimezoneDropdown(),
          const SizedBox(height: 14),
          _buildPronounsField(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Accessibility & layout widgets for page 2
  // ---------------------------------------------------------------------------

  Widget _buildMessageLayoutChips() {
    final layout = ref.watch(messageLayoutProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Message Layout',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ChoiceChip(
              label: const Text('Bubbles'),
              selected: layout == MessageLayout.bubbles,
              onSelected: (_) => ref
                  .read(messageLayoutProvider.notifier)
                  .setLayout(MessageLayout.bubbles),
              selectedColor: context.accent,
              labelStyle: TextStyle(
                color: layout == MessageLayout.bubbles
                    ? Colors.white
                    : context.textPrimary,
                fontSize: 13,
              ),
              backgroundColor: context.surface,
              side: BorderSide(color: context.border),
            ),
            const SizedBox(width: 10),
            ChoiceChip(
              label: const Text('Compact'),
              selected: layout == MessageLayout.compact,
              onSelected: (_) => ref
                  .read(messageLayoutProvider.notifier)
                  .setLayout(MessageLayout.compact),
              selectedColor: context.accent,
              labelStyle: TextStyle(
                color: layout == MessageLayout.compact
                    ? Colors.white
                    : context.textPrimary,
                fontSize: 13,
              ),
              backgroundColor: context.surface,
              side: BorderSide(color: context.border),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFontSizeSlider() {
    final a11y = ref.watch(accessibilityProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Font Size',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        Slider(
          value: a11y.fontScale,
          min: 0.8,
          max: 1.5,
          divisions: 7,
          label: '${(a11y.fontScale * 100).round()}%',
          activeColor: context.accent,
          inactiveColor: context.border,
          onChanged: (v) =>
              ref.read(accessibilityProvider.notifier).setFontScale(v),
        ),
      ],
    );
  }

  Widget _buildAccessibilityToggles() {
    final a11y = ref.watch(accessibilityProvider);
    return Column(
      children: [
        SwitchListTile(
          title: Text(
            'Reduced Motion',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          value: a11y.reducedMotion,
          activeTrackColor: context.accent,
          contentPadding: EdgeInsets.zero,
          dense: true,
          onChanged: (v) =>
              ref.read(accessibilityProvider.notifier).setReducedMotion(v),
        ),
        SwitchListTile(
          title: Text(
            'High Contrast',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          value: a11y.highContrast,
          activeTrackColor: context.accent,
          contentPadding: EdgeInsets.zero,
          dense: true,
          onChanged: (v) =>
              ref.read(accessibilityProvider.notifier).setHighContrast(v),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Page 3 -- Add contact
  // ---------------------------------------------------------------------------

  Widget _buildContactPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            'Add your first contact',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Send a contact request to start chatting.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          _buildField(
            controller: _contactUsernameController,
            label: 'Username',
            hint: 'Enter a username',
            maxLength: 32,
            onSubmitted: (_) => _sendContactRequest(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _sendingRequest ? null : _sendContactRequest,
              icon: _sendingRequest
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.textSecondary,
                      ),
                    )
                  : const Icon(Icons.person_add, size: 18),
              label: const Text('Send Request'),
            ),
          ),
          if (_contactResult != null) ...[
            const SizedBox(height: 12),
            Text(
              _contactResult!,
              style: TextStyle(
                color: _contactResult!.startsWith('Failed')
                    ? EchoTheme.danger
                    : EchoTheme.online,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 24),
          TextButton(
            onPressed: _saving ? null : _skip,
            child: Text(
              'Skip for now',
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom controls
  // ---------------------------------------------------------------------------

  Widget _buildBottomControls(BuildContext context) {
    return Column(
      children: [
        // Dot indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (i) {
            final isActive = i == _currentPage;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: isActive ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: isActive
                    ? context.accent
                    : context.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        ),
        const SizedBox(height: 20),

        // Buttons
        Builder(
          builder: (_) {
            final buttonLabel = _currentPage == 3 ? 'Get Started' : 'Next';
            return Row(
              children: [
                // Skip button (hidden on last page -- "Skip for now" is inline)
                if (_currentPage < 3)
                  TextButton(
                    onPressed: _saving ? null : _skip,
                    child: Text(
                      'Skip',
                      style: TextStyle(color: context.textMuted),
                    ),
                  ),
                const Spacer(),
                // Next / Get Started
                SizedBox(
                  width: 160,
                  child: FilledButton(
                    onPressed: _saving ? null : _next,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(buttonLabel),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared input field builder
  // ---------------------------------------------------------------------------

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLength = 100,
    int maxLines = 1,
    void Function(String)? onSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      onFieldSubmitted: onSubmitted,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: context.textSecondary),
        hintStyle: TextStyle(color: context.textMuted),
        counterStyle: TextStyle(color: context.textMuted, fontSize: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}
