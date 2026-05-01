import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../services/upload_client.dart';
import '../theme/echo_theme.dart';
import '../utils/friendly_error.dart';
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

  // TODO: move to Settings > Profile (bio, pronouns, timezone)
  final _pronounsController = TextEditingController();
  final _bioController = TextEditingController();
  final _statusController = TextEditingController();
  final _timezoneController = TextEditingController();

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
    if (_currentPage < 2) {
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

    setState(() => _pickedAvatar = file);
    await _uploadAvatar(file);
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
      await ref.read(contactsProvider.notifier).sendRequest(username);
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
                        _buildEncryptionPage(context),
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
          Semantics(
            label: 'pick avatar',
            button: true,
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
  // Encryption explanation page
  // ---------------------------------------------------------------------------

  Widget _buildEncryptionPage(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.lock_outline, size: 64, color: context.accent),
          const SizedBox(height: 24),
          Text(
            'Your messages are private',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Echo uses the Signal Protocol to encrypt your messages '
              'end-to-end. Only you and the person you are talking to '
              'can read them -- not even our servers can see the content.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'You can verify a contact\'s identity at any time '
              'by comparing Safety Numbers in their profile.',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 13,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page 4 -- Add contact
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

          Card(
            color: context.surface,
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('Share invite link'),
                  onTap: () {
                    final username = ref.read(authProvider).username ?? '';
                    final url = 'https://echo-messenger.us/invite/$username';
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite link copied')),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.qr_code),
                  title: const Text('Show QR code'),
                  onTap: () {
                    final username = ref.read(authProvider).username ?? '';
                    final url = 'https://echo-messenger.us/invite/$username';
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Your invite QR'),
                        content: QrImageView(data: url, size: 200),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

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
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _saving ? null : _skip,
              child: const Text('Skip for now'),
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
          children: List.generate(3, (i) {
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
            final buttonLabel = _currentPage == 2 ? 'Get Started' : 'Next';
            return Row(
              children: [
                // Back button (hidden on first page)
                if (_currentPage > 0)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _goToPage(_currentPage - 1),
                    child: Text(
                      'Back',
                      style: TextStyle(color: context.textMuted),
                    ),
                  ),
                // Skip button (hidden on last page -- "Skip for now" is inline)
                if (_currentPage < 2)
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
