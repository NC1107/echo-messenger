import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/accessibility_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/theme_provider.dart';
import '../services/notification_service.dart';
import '../services/sound_service.dart';
import '../services/toast_service.dart';
import '../services/upload_client.dart';
import '../theme/echo_theme.dart';
import '../utils/friendly_error.dart';
import '../widgets/avatar_crop_dialog.dart';
import '../widgets/echo_logo_icon.dart';
import '../widgets/theme_thumbnail.dart';
import '../widgets/window_chrome.dart';

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

  // Profile fields shown inline on the Welcome page (the user can also edit
  // these later under Settings > Profile).
  String? _selectedPronouns;
  final _customPronounsController = TextEditingController();
  final _bioController = TextEditingController();
  final _statusController = TextEditingController();
  String _selectedTimezone = '';

  // Presence/status field was removed from the onboarding wizard in #999
  // — defaults to 'online' on the server, editable later from Settings.

  // Notifications wizard page state. Mirrors prefs used by Settings >
  // Notifications so the user's choices here are picked up the same way.
  bool _soundEnabled = true;
  bool _mentionOnly = false;
  bool _notificationPermissionGranted = false;
  bool _requestingPermission = false;

  static const String _kMentionOnlyPref = 'notifications_mention_only';

  // Add-contact onboarding step removed; user can add contacts after
  // landing on the home screen.

  // UI style step — which chat-app familiarity the user picks.
  _AppFamiliarity? _selectedStyle;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedTimezone = DateTime.now().timeZoneName;
    // Pre-fill display name with username so Skip on Welcome doesn't hard-block (#1177).
    final username = ref.read(authProvider).username;
    if (username != null && username.isNotEmpty) {
      _displayNameController.text = username;
    }
    _loadNotificationPrefs();
    _initStyleSelection();
  }

  void _initStyleSelection() {
    final layout = ref.read(messageLayoutProvider);
    final density = ref.read(uiDensityProvider);
    _selectedStyle = _reverseMapStyle(layout, density);
  }

  static _AppFamiliarity? _reverseMapStyle(
    MessageLayout layout,
    UIDensity density,
  ) {
    if (layout == MessageLayout.compact && density == UIDensity.compact) {
      return _AppFamiliarity.discord;
    }
    if (layout == MessageLayout.plain && density == UIDensity.normal) {
      return _AppFamiliarity.slack;
    }
    if (layout == MessageLayout.bubbles && density == UIDensity.cozy) {
      return _AppFamiliarity.imessage;
    }
    return null;
  }

  Future<void> _loadNotificationPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _soundEnabled = SoundService().enabled;
      _mentionOnly = prefs.getBool(_kMentionOnlyPref) ?? false;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _displayNameController.dispose();
    _customPronounsController.dispose();
    _bioController.dispose();
    _statusController.dispose();
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

  /// Total number of wizard pages. Kept in sync with the `PageView` children
  /// built below. Update both when adding/removing a step.
  static const int _pageCount = 6;

  void _next() {
    // Display name is the only required wizard field; block forward nav until set.
    if (_currentPage == 0 && _displayNameController.text.trim().isEmpty) {
      _showDisplayNameRequired();
      return;
    }
    if (_currentPage < _pageCount - 1) {
      _goToPage(_currentPage + 1);
    } else {
      _finish();
    }
  }

  void _skip() {
    if (_displayNameController.text.trim().isEmpty) {
      _showDisplayNameRequired();
      return;
    }
    _finish();
  }

  void _showDisplayNameRequired() {
    if (!mounted) return;
    ToastService.show(
      context,
      'Pick a display name before continuing.',
      type: ToastType.warning,
    );
  }

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
    // Resolve pronouns: use custom text when "Custom" is chosen, otherwise
    // use the selected preset (or empty string if none selected).
    final pronounsValue = _selectedPronouns == 'custom'
        ? _customPronounsController.text.trim()
        : (_selectedPronouns ?? '');
    final body = <String, dynamic>{
      'display_name': _displayNameController.text,
      'bio': _bioController.text,
      'status_message': _statusController.text,
      'pronouns': pronounsValue,
      'timezone': _selectedTimezone,
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
    // Home screen should check 'profile_nudge_shown' to prompt the user
    // to complete their profile (bio, pronouns, timezone) in Settings > Profile.
    await prefs.setBool('profile_nudge_shown', false);
  }

  // ---------------------------------------------------------------------------
  // Avatar upload
  // ---------------------------------------------------------------------------

  Future<void> _pickAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    // Reuse Settings → Profile crop dialog for aspect-correct avatar (#728).
    if (!mounted) return;
    final croppedBytes = await showAvatarCropDialog(context, file.bytes!);
    if (croppedBytes == null) return;

    final croppedFile = PlatformFile(
      name: 'avatar.jpg',
      size: croppedBytes.length,
      bytes: croppedBytes,
    );
    setState(() => _pickedAvatar = croppedFile);
    await _uploadAvatar(croppedFile);
  }

  Future<void> _uploadAvatar(PlatformFile file) async {
    final serverUrl = ref.read(serverUrlProvider);

    setState(() => _uploadingAvatar = true);
    try {
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final result = await uploader.uploadFile(
        serverUrl: serverUrl,
        path: '/api/users/me/avatar',
        bytes: file.bytes!,
        fileName: file.name,
        mimeType: 'image/jpeg',
        method: 'PUT',
        fieldName: 'avatar',
      );
      if (!mounted) return;

      if (result.ok) {
        if (result.url != null) {
          ref.read(authProvider.notifier).updateAvatarUrl(result.url!);
        }
        ToastService.show(context, 'Avatar uploaded', type: ToastType.success);
      } else {
        ToastService.show(
          context,
          result.errorMessage ?? 'Avatar upload failed (${result.statusCode})',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[Onboarding] avatar upload failed: $e');
      if (mounted) {
        ToastService.show(context, friendlyError(e), type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mainBg,
      body: Column(
        children: [
          const AppTitleBar(),
          Expanded(
            child: SafeArea(
              // top safe area: avoid iOS status bar / dynamic island collision.
              child: Center(
                child: LayoutBuilder(
                  builder: (context, outerConstraints) {
                    final w = outerConstraints.maxWidth;
                    if (w >= 900) {
                      return _buildWideLayout(context);
                    }
                    return _buildNarrowLayout(context, w);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Phone / narrow-tablet layout: single centred column, 520 px max.
  Widget _buildNarrowLayout(BuildContext context, double width) {
    final effectiveMax = width < 500 ? double.infinity : 520.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: effectiveMax),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            // Logo removed on narrow: Welcome header already brands, and iOS dynamic island collided.
            Expanded(child: _buildPageView()),
            const SizedBox(height: 16),
            _buildBottomControls(context),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Desktop / wide-tablet layout (≥ 900 px): two-pane card with a brand
  /// panel on the left and the active step on the right. Keeps the wizard
  /// visually balanced in horizontal viewports instead of rendering as a
  /// phone-tall column on a 1920 px screen.
  Widget _buildWideLayout(BuildContext context) {
    final stepTitles = [
      'Welcome',
      'Choose your look',
      'Your style',
      'Comfort settings',
      'Notifications',
      'Encryption',
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960, maxHeight: 640),
      child: Container(
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand panel
            SizedBox(
              width: 320,
              child: Container(
                color: context.accent.withValues(alpha: 0.08),
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const EchoLogoIcon(size: 48),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome to Echo',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 32),
                    for (var i = 0; i < stepTitles.length; i++) ...[
                      _stepIndicatorRow(context, i, stepTitles[i]),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            // Step content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
                child: Column(
                  children: [
                    Expanded(child: _buildPageView()),
                    const SizedBox(height: 12),
                    _buildBottomControls(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepIndicatorRow(BuildContext context, int index, String label) {
    final isActive = index == _currentPage;
    final isDone = index < _currentPage;
    final dotColor = _resolveStepDotColor(context, isActive, isDone);
    final textColor = _resolveStepTextColor(context, isActive, isDone);
    final row = Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
    // Backwards-only step nav: completed steps clickable, future ones blocked.
    if (!isDone) return row;
    return Semantics(
      button: true,
      label: 'go back to $label',
      child: InkWell(
        onTap: () => _goToPage(index),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: row,
        ),
      ),
    );
  }

  Color _resolveStepDotColor(BuildContext context, bool isActive, bool isDone) {
    if (isActive) return context.accent;
    if (isDone) return context.accent.withValues(alpha: 0.6);
    return context.border;
  }

  Color _resolveStepTextColor(
    BuildContext context,
    bool isActive,
    bool isDone,
  ) {
    if (isActive) return context.textPrimary;
    if (isDone) return context.textSecondary;
    return context.textMuted;
  }

  Widget _buildPageView() {
    return PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: (i) => setState(() => _currentPage = i),
      children: [
        _buildWelcomePage(context),
        _buildThemePage(context),
        _buildAppStylePage(context),
        _buildAccessibilityPage(context),
        _buildNotificationsPage(context),
        _buildEncryptionPage(context),
      ],
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
          // Beta callout lives on login/register (BetaBanner); wizard leads with the setup CTA.
          Text(
            'Welcome to Echo!',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 20),

          // Avatar circle
          Semantics(
            label: 'pick avatar',
            button: true,
            child: SizedBox(
              width: 120,
              height: 120,
              child: GestureDetector(
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
            ),
          ),
          const SizedBox(height: 16),

          // Required fields are marked with a trailing asterisk; the rest
          // can be edited later in Settings.
          _buildField(
            controller: _displayNameController,
            label: 'Display Name *',
            hint: 'How others will see you',
            maxLength: 50,
          ),
          const SizedBox(height: 12),
          _buildField(
            controller: _bioController,
            label: 'Bio',
            hint: 'Tell people a little about yourself',
            maxLength: 200,
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          _buildPronounsDropdown(context),
          if (_selectedPronouns == 'custom') ...[
            const SizedBox(height: 8),
            _buildField(
              controller: _customPronounsController,
              label: 'Custom pronouns',
              hint: 'e.g. xe/xem',
              maxLength: 32,
            ),
          ],
          const SizedBox(height: 12),
          _buildTimezoneDropdown(context),
          // Presence dropdown removed; defaults to 'online', editable in Settings → Status.
        ],
      ),
    );
  }

  // _buildPresenceDropdown removed — presence/status was dropped from
  // onboarding (defaults to 'online', editable later in Settings).

  // ---------------------------------------------------------------------------
  // Pronouns dropdown
  // ---------------------------------------------------------------------------

  static const List<({String value, String label})> _pronounsOptions = [
    (value: 'he/him', label: 'he/him'),
    (value: 'she/her', label: 'she/her'),
    (value: 'they/them', label: 'they/them'),
    (value: 'he/they', label: 'he/they'),
    (value: 'she/they', label: 'she/they'),
    (value: 'custom', label: 'Custom…'),
  ];

  Widget _buildPronounsDropdown(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Pronouns (optional)',
        labelStyle: TextStyle(color: context.textSecondary),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isDense: true,
          isExpanded: true,
          hint: Text(
            'Select pronouns',
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
          value: _selectedPronouns,
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          onChanged: (v) => setState(() {
            _selectedPronouns = v;
            if (v != 'custom') _customPronounsController.clear();
          }),
          items: [
            for (final opt in _pronounsOptions)
              DropdownMenuItem(value: opt.value, child: Text(opt.label)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Timezone dropdown
  // ---------------------------------------------------------------------------

  /// A curated list of representative IANA timezone identifiers shown in the
  /// picker. Not exhaustive — the full list is ~600 entries. The auto-detected
  /// name from [DateTime.now().timeZoneName] (e.g. "EST") may not appear here;
  /// we add it dynamically so the initial selection always resolves.
  static const List<String> _commonTimezones = [
    'Pacific/Honolulu',
    'America/Anchorage',
    'America/Los_Angeles',
    'America/Denver',
    'America/Chicago',
    'America/New_York',
    'America/Sao_Paulo',
    'Atlantic/Reykjavik',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Helsinki',
    'Europe/Moscow',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Dhaka',
    'Asia/Bangkok',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Australia/Sydney',
    'Pacific/Auckland',
  ];

  Widget _buildTimezoneDropdown(BuildContext context) {
    // Ensure the auto-detected value (e.g. "EST") is always in the list
    // even when it doesn't match a canonical IANA name.
    final tzList = [
      if (!_commonTimezones.contains(_selectedTimezone)) _selectedTimezone,
      ..._commonTimezones,
    ];

    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Timezone',
        labelStyle: TextStyle(color: context.textSecondary),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isDense: true,
          isExpanded: true,
          value: _selectedTimezone,
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          onChanged: (v) {
            if (v != null) setState(() => _selectedTimezone = v);
          },
          items: [
            for (final tz in tzList)
              DropdownMenuItem(value: tz, child: Text(tz)),
          ],
        ),
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
  // Theme picker page
  // ---------------------------------------------------------------------------

  /// Themes surfaced in the onboarding picker. Matches [kCuratedThemes] from
  /// theme_provider.dart: System, Indigo, Paper, Ember. Each entry carries a
  /// rich `ThemeThumbnail`-compatible preview so the wizard renders the same
  /// mini chat-mockup the Settings picker uses instead of a flat colour swatch.
  static const List<_WizardThemeOption> _wizardThemes = [
    _WizardThemeOption(
      selection: AppThemeSelection.system,
      label: 'System',
      preview: null, // split dark/light preview
    ),
    _WizardThemeOption(
      selection: AppThemeSelection.indigo,
      label: 'Indigo',
      preview: indigoPreview,
    ),
    _WizardThemeOption(
      selection: AppThemeSelection.paper,
      label: 'Paper',
      preview: lightPreview,
    ),
    _WizardThemeOption(
      selection: AppThemeSelection.ember,
      label: 'Ember',
      preview: emberPreview,
    ),
  ];

  Widget _buildThemePage(BuildContext context) {
    final current = ref.watch(themeProvider);
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text(
            'Choose your look',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pick a theme. You can change this any time in Settings.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              // Four curated themes: 2-column grid on wide, single column on
              // small phones (< 360 px).
              final cols = constraints.maxWidth >= 360 ? 2 : 1;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: cols,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: cols == 1 ? 1.8 : 0.95,
                children: [
                  for (final t in _wizardThemes)
                    _WizardThemeCard(
                      label: t.label,
                      preview: t.preview,
                      isSelected: current == t.selection,
                      onTap: () => ref
                          .read(themeProvider.notifier)
                          .setTheme(t.selection),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI style step (which app are you used to?)
  // ---------------------------------------------------------------------------

  static const List<_AppStyleCardData> _appStyleOptions = [
    _AppStyleCardData(
      style: _AppFamiliarity.discord,
      layout: MessageLayout.compact,
      density: UIDensity.compact,
      label: 'Discord',
      subtitle: 'Grouped, compact rows — dense like Discord',
      icon: Icons.format_align_left_outlined,
    ),
    _AppStyleCardData(
      style: _AppFamiliarity.slack,
      layout: MessageLayout.plain,
      density: UIDensity.normal,
      label: 'Slack',
      subtitle: 'Clean left-aligned feed, comfortable spacing',
      icon: Icons.notes_outlined,
    ),
    _AppStyleCardData(
      style: _AppFamiliarity.imessage,
      layout: MessageLayout.bubbles,
      density: UIDensity.cozy,
      label: 'iMessage',
      subtitle: 'Chat bubbles with relaxed spacing',
      icon: Icons.chat_bubble_outline,
    ),
  ];

  Widget _buildAppStylePage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text(
            'Which app are you used to?',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Echo will match the style you know. Change it later in '
            'Settings → Appearance.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          for (final opt in _appStyleOptions) ...[
            _StyleCard(
              data: opt,
              isSelected: _selectedStyle == opt.style,
              onTap: () => _applyStyle(opt),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  void _applyStyle(_AppStyleCardData opt) {
    setState(() => _selectedStyle = opt.style);
    ref.read(messageLayoutProvider.notifier).setLayout(opt.layout);
    ref.read(uiDensityProvider.notifier).setDensity(opt.density);
  }

  // ---------------------------------------------------------------------------
  // Accessibility prefs page
  // ---------------------------------------------------------------------------

  Widget _buildAccessibilityPage(BuildContext context) {
    final a11y = ref.watch(accessibilityProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(
            'Make Echo comfortable',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Tune text size and motion. You can change these later in '
            'Settings > Accessibility.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            'Text size',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          Slider(
            value: a11y.fontScale.clamp(0.8, 1.4),
            min: 0.8,
            max: 1.4,
            divisions: 6,
            label: '${(a11y.fontScale * 100).round()}%',
            onChanged: (v) =>
                ref.read(accessibilityProvider.notifier).setFontScale(v),
          ),
          // Live preview so the slider has visible feedback.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.border),
            ),
            child: Text(
              'The quick brown fox jumps over the lazy dog.',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14 * a11y.fontScale,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Reduce motion',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Limits animations and transitions.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: a11y.reducedMotion,
            onChanged: (v) =>
                ref.read(accessibilityProvider.notifier).setReducedMotion(v),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'High contrast',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Boosts text and border contrast on top of your chosen theme.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: a11y.highContrast,
            onChanged: (v) =>
                ref.read(accessibilityProvider.notifier).setHighContrast(v),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Notifications prefs page
  // ---------------------------------------------------------------------------

  Future<void> _setSoundEnabled(bool value) async {
    setState(() => _soundEnabled = value);
    SoundService().enabled = value;
  }

  Future<void> _setMentionOnly(bool value) async {
    setState(() => _mentionOnly = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMentionOnlyPref, value);
  }

  Future<void> _grantNotificationPermission() async {
    setState(() => _requestingPermission = true);
    try {
      final granted = await NotificationService().promptPermission();
      if (mounted) {
        setState(() {
          _notificationPermissionGranted = granted;
          _requestingPermission = false;
        });
      }
    } catch (e) {
      debugPrint('[Onboarding] permission request failed: $e');
      if (mounted) setState(() => _requestingPermission = false);
    }
  }

  Widget _buildNotificationsPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(
            'Stay in the loop',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Pick how Echo should ping you. Adjust later under '
            'Settings > Notifications.',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Notification sounds',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Play a tone for new messages.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: _soundEnabled,
            onChanged: _setSoundEnabled,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Only notify on mentions',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Stay quiet unless someone @mentions you.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: _mentionOnly,
            onChanged: _setMentionOnly,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.border),
            ),
            child: Row(
              children: [
                Icon(
                  _notificationPermissionGranted
                      ? Icons.check_circle_outline
                      : Icons.notifications_off_outlined,
                  size: 18,
                  color: _notificationPermissionGranted
                      ? EchoTheme.online
                      : context.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _notificationPermissionGranted
                        ? 'OS notifications enabled.'
                        : 'OS notifications are off.',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (!_notificationPermissionGranted)
                  TextButton(
                    onPressed: _requestingPermission
                        ? null
                        : _grantNotificationPermission,
                    child: _requestingPermission
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Grant'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Encryption explanation page
  // ---------------------------------------------------------------------------

  Widget _buildEncryptionPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 48),
          Icon(Icons.lock_outline, size: 72, color: context.accent),
          const SizedBox(height: 28),
          Text(
            'Private by default',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Your messages are end-to-end encrypted. Only you and the '
              "person you're talking to can read them — not us, not your "
              'network, not anyone else.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                height: 1.55,
              ),
              textAlign: TextAlign.center,
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
        _buildPageIndicatorDots(),
        const SizedBox(height: 16),
        _buildNavigationButtons(),
      ],
    );
  }

  Widget _buildPageIndicatorDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pageCount, (i) {
        final isActive = i == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: isActive ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: isActive
                ? context.accent
                : context.textMuted.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _buildNavigationButtons() {
    final isLast = _currentPage == _pageCount - 1;
    final buttonLabel = isLast ? 'Get Started' : 'Next';

    return Row(
      children: [
        if (_currentPage > 0)
          TextButton(
            onPressed: _saving ? null : () => _goToPage(_currentPage - 1),
            child: Text('Back', style: TextStyle(color: context.textMuted)),
          ),
        if (!isLast)
          TextButton(
            onPressed: _saving ? null : _skip,
            child: Text('Skip', style: TextStyle(color: context.textSecondary)),
          ),
        const Spacer(),
        FilledButton(
          onPressed: _saving ? null : _next,
          style: FilledButton.styleFrom(minimumSize: const Size(120, 40)),
          child: _buildNextButtonContent(buttonLabel),
        ),
      ],
    );
  }

  Widget _buildNextButtonContent(String label) {
    return _saving
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Text(label);
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

/// Which chat app the user is most familiar with. Used only within the
/// onboarding wizard to drive the style-card selection state; the actual
/// persisted preferences are [MessageLayout] + [UIDensity].
enum _AppFamiliarity { discord, slack, imessage }

/// Data holder for one UI-style card in the onboarding picker.
class _AppStyleCardData {
  final _AppFamiliarity style;
  final MessageLayout layout;
  final UIDensity density;
  final String label;
  final String subtitle;
  final IconData icon;

  const _AppStyleCardData({
    required this.style,
    required this.layout,
    required this.density,
    required this.label,
    required this.subtitle,
    required this.icon,
  });
}

/// Card for the app-familiarity step. Extracted to keep [_buildAppStylePage]
/// under the cognitive-complexity budget (S3776).
class _StyleCard extends StatelessWidget {
  final _AppStyleCardData data;
  final bool isSelected;
  final VoidCallback onTap;

  const _StyleCard({
    required this.data,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${data.label} style',
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? context.accentLight : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? context.accent : context.border,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  data.icon,
                  size: 28,
                  color: isSelected ? context.accent : context.textSecondary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.label,
                        style: TextStyle(
                          color: isSelected
                              ? context.accent
                              : context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        data.subtitle,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle,
                      size: 20,
                      color: context.accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tuple describing one wizard theme card. `preview == null` means render
/// the system "follow-OS" split preview instead of the regular mini chat.
class _WizardThemeOption {
  final AppThemeSelection selection;
  final String label;
  final ThemePreviewColors? preview;

  const _WizardThemeOption({
    required this.selection,
    required this.label,
    required this.preview,
  });
}

/// Compact theme card used by the onboarding wizard. Renders the same
/// rich mini chat preview the Settings → Appearance picker uses so users
/// see actual sent/received bubble colours instead of a flat colour swatch.
class _WizardThemeCard extends StatelessWidget {
  final String label;
  final ThemePreviewColors? preview;
  final bool isSelected;
  final VoidCallback onTap;

  const _WizardThemeCard({
    required this.label,
    required this.preview,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label theme',
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? context.accentLight : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? context.accent : context.border,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 1.4,
                  child: preview != null
                      ? ThemeThumbnail(colors: preview!)
                      : const SystemThemeThumbnail(),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? context.accent : context.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
