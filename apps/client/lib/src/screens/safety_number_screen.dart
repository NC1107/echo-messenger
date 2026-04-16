/// Screen for displaying and verifying safety numbers between two peers.
///
/// Shows the 60-digit safety number derived from both users' identity keys,
/// formatted in groups of 5 for easy comparison. Includes a QR code
/// representation and a verification toggle that persists locally.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/crypto_provider.dart';
import '../services/safety_number_service.dart';
import '../services/secure_key_store.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';

/// Displays and manages safety number verification for a DM conversation.
///
/// On desktop (>=900px) opens as a dialog; on smaller screens pushes a
/// full-screen route.
class SafetyNumberScreen extends ConsumerStatefulWidget {
  final String peerUserId;
  final String peerUsername;
  final String myUsername;

  const SafetyNumberScreen({
    super.key,
    required this.peerUserId,
    required this.peerUsername,
    required this.myUsername,
  });

  /// Open the safety number screen as a dialog on desktop or full-screen
  /// route on mobile.
  static void show(
    BuildContext context,
    WidgetRef ref, {
    required String peerUserId,
    required String peerUsername,
    required String myUsername,
  }) {
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
            width: 440,
            height: 580,
            child: SafetyNumberScreen(
              peerUserId: peerUserId,
              peerUsername: peerUsername,
              myUsername: myUsername,
            ),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SafetyNumberScreen(
            peerUserId: peerUserId,
            peerUsername: peerUsername,
            myUsername: myUsername,
          ),
        ),
      );
    }
  }

  @override
  ConsumerState<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends ConsumerState<SafetyNumberScreen> {
  _SafetyScreenMode _mode = _SafetyScreenMode.verify;
  String? _safetyNumber;
  bool _isLoading = true;
  String? _error;
  bool _isVerified = false;

  static const _verifiedPrefix = 'echo_safety_verified_';

  @override
  void initState() {
    super.initState();
    _loadSafetyNumber();
  }

  Future<void> _loadSafetyNumber() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final store = SecureKeyStore.instance;
      final crypto = ref.read(cryptoServiceProvider);

      // Load my identity public key -- if missing, try initializing crypto
      // first, since the user may have just logged in.
      var myPubB64 = await store.read('echo_identity_pub_key');
      if (myPubB64 == null && crypto.isInitialized) {
        final pubBytes = await crypto.getIdentityPublicKey();
        if (pubBytes != null) {
          myPubB64 = base64Encode(pubBytes);
        }
      }
      if (myPubB64 == null) {
        setState(() {
          _error =
              'Your encryption keys have not been set up yet. '
              'Send a message first to initialize encryption, then '
              'come back to verify the safety number.';
          _isLoading = false;
        });
        return;
      }
      final myPub = Uint8List.fromList(base64Decode(myPubB64));

      // Load peer identity public key from cached prekey bundle
      final peerPubB64 = await store.read(
        'echo_peer_identity_${widget.peerUserId}',
      );
      Uint8List? peerPub;
      if (peerPubB64 != null) {
        peerPub = Uint8List.fromList(base64Decode(peerPubB64));
      } else {
        // Try to fetch from server via crypto service
        peerPub = await crypto.fetchPeerIdentityKey(widget.peerUserId);
      }

      if (peerPub == null) {
        setState(() {
          _error =
              '${widget.peerUsername}\'s identity key is not available yet. '
              'Exchange at least one message so both devices can share '
              'keys, then check back here.';
          _isLoading = false;
        });
        return;
      }

      _safetyNumber = await SafetyNumberService.generate(myPub, peerPub);

      // Load verification state
      final prefs = await SharedPreferences.getInstance();
      _isVerified =
          prefs.getBool('$_verifiedPrefix${widget.peerUserId}') ?? false;

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _error = 'Failed to generate safety number: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleVerified() async {
    final newState = !_isVerified;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_verifiedPrefix${widget.peerUserId}', newState);
    setState(() => _isVerified = newState);

    if (!mounted) return;
    ToastService.show(
      context,
      newState ? 'Marked as verified' : 'Verification removed',
      type: newState ? ToastType.success : ToastType.info,
    );
  }

  String get _inviteUrl =>
      'https://echo-messenger.us/#/u/${Uri.encodeComponent(widget.myUsername)}';

  Future<void> _copyInviteMessage() async {
    final text =
        'Add me on Echo Messenger: $_inviteUrl';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ToastService.show(
      context,
      'Invite message copied',
      type: ToastType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDialog = Responsive.isDesktop(context);

    return Scaffold(
      backgroundColor: isDialog ? Colors.transparent : context.mainBg,
      appBar: isDialog
          ? null
          : AppBar(
              backgroundColor: context.chatBg,
              title: const Text('Safety Number'),
              foregroundColor: context.textPrimary,
            ),
      body: _buildBody(context, isDialog),
    );
  }

  Widget _buildBody(BuildContext context, bool isDialog) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 48, color: context.textMuted),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _loadSafetyNumber,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.accent,
                  side: BorderSide(color: context.accent),
                ),
              ),
              if (isDialog) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final formatted = SafetyNumberService.formatForDisplay(_safetyNumber!);
    final isAddContactMode = _mode == _SafetyScreenMode.addContact;
    final qrData = isAddContactMode ? _inviteUrl : _safetyNumber!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          if (isDialog)
            Row(
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 20,
                  color: context.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  'Safety Number',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: context.textMuted),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          const SizedBox(height: 8),
          SegmentedButton<_SafetyScreenMode>(
            selected: {_mode},
            onSelectionChanged: (selection) {
              if (selection.isNotEmpty) {
                setState(() => _mode = selection.first);
              }
            },
            segments: const [
              ButtonSegment(
                value: _SafetyScreenMode.verify,
                icon: Icon(Icons.verified_user_outlined, size: 16),
                label: Text('Verify'),
              ),
              ButtonSegment(
                value: _SafetyScreenMode.addContact,
                icon: Icon(Icons.person_add_alt_1, size: 16),
                label: Text('Add Contact'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isAddContactMode
                ? 'Show this QR or link to let others add you using your username invite.'
                : 'Verify that the safety number below matches on both '
                      '${widget.myUsername}\'s and ${widget.peerUsername}\'s devices.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 24),

          // QR code
          Container(
            padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 160,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),

          if (isAddContactMode) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.border),
              ),
              child: Column(
                children: [
                  SelectableText(
                    _inviteUrl,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: _inviteUrl));
                            if (!mounted) return;
                            ToastService.show(
                              context,
                              'Invite link copied',
                              type: ToastType.success,
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy Link'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copyInviteMessage,
                          icon: const Icon(Icons.share, size: 16),
                          label: const Text('Copy Share Text'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Anyone scanning this QR opens your DM invite. If they are not a contact yet, Echo sends a contact request first.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
          ] else ...[
            // Safety number digits
            Semantics(
              label: 'copy safety number',
              button: true,
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _safetyNumber!));
                  ToastService.show(
                    context,
                    'Safety number copied',
                    type: ToastType.success,
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.border),
                  ),
                  child: Column(
                    children: [
                      Text(
                        formatted,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'monospace',
                          letterSpacing: 2,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.copy, size: 12, color: context.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            'Tap to copy',
                            style: TextStyle(
                              color: context.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Verification button
            SizedBox(
              width: double.infinity,
              child: _isVerified
                  ? OutlinedButton.icon(
                      onPressed: _toggleVerified,
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text('Verified'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: EchoTheme.online,
                        side: const BorderSide(color: EchoTheme.online),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: _toggleVerified,
                      icon: const Icon(Icons.verified_user_outlined, size: 18),
                      label: const Text('Mark as Verified'),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              'If the numbers match, tap to mark this conversation as verified. '
              'If they change later, the session may have been re-established.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

enum _SafetyScreenMode { verify, addContact }
