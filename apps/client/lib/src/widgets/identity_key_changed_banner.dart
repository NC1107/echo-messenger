import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/crypto_provider.dart';
import '../screens/safety_number_screen.dart';
import '../theme/echo_theme.dart';

/// Displays an amber warning banner when a DM peer's identity key has changed
/// (TOFU violation). Offers "View Safety Number" and "Dismiss" actions.
///
/// Only shown for 1:1 (non-group) conversations when the crypto layer has
/// detected that the peer re-registered or regenerated their identity key.
class IdentityKeyChangedBanner extends ConsumerStatefulWidget {
  final Conversation conversation;

  const IdentityKeyChangedBanner({super.key, required this.conversation});

  @override
  ConsumerState<IdentityKeyChangedBanner> createState() =>
      _IdentityKeyChangedBannerState();
}

class _IdentityKeyChangedBannerState
    extends ConsumerState<IdentityKeyChangedBanner> {
  bool _checked = false;
  bool _changed = false;
  String? _peerUserId;
  String _peerUsername = '';

  @override
  void initState() {
    super.initState();
    _checkIdentityKey();
  }

  @override
  void didUpdateWidget(covariant IdentityKeyChangedBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation.id != oldWidget.conversation.id) {
      _checked = false;
      _changed = false;
      _checkIdentityKey();
    }
  }

  Future<void> _checkIdentityKey() async {
    final conv = widget.conversation;
    if (conv.isGroup) return;

    final myUserId = ref.read(authProvider).userId ?? '';
    final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
    if (peer == null) return;

    _peerUserId = peer.userId;
    _peerUsername = peer.username;

    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) return;

    final changed = await ref
        .read(cryptoProvider.notifier)
        .hasPeerIdentityKeyChanged(peer.userId);

    if (changed) {
      // Reset any prior safety-number verification for this peer -- a new
      // identity key means the old verification no longer applies.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('echo_safety_verified_${peer.userId}');
      } catch (_) {
        // Best-effort; verification state is cosmetic.
      }
    }

    if (mounted) {
      setState(() {
        _checked = true;
        _changed = changed;
      });
    }
  }

  Future<void> _dismiss() async {
    if (_peerUserId == null) return;
    await ref
        .read(cryptoProvider.notifier)
        .acknowledgePeerIdentityKeyChange(_peerUserId!);
    if (mounted) {
      setState(() => _changed = false);
    }
  }

  /// Explicitly trust the peer's new identity key. Drops the old session
  /// and clears the change flag so the next outbound message X3DH's
  /// against the freshly-trusted key.
  Future<void> _trustNewKey() async {
    if (_peerUserId == null) return;
    await ref
        .read(cryptoProvider.notifier)
        .acceptIdentityKeyChange(_peerUserId!);
    if (mounted) {
      setState(() => _changed = false);
    }
  }

  void _viewSafetyNumber() {
    if (_peerUserId == null) return;
    final myName = ref.read(authProvider).username ?? 'You';
    SafetyNumberScreen.show(
      context,
      ref,
      peerUserId: _peerUserId!,
      peerUsername: _peerUsername,
      myUsername: myName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _checked && _changed;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: visible
          ? Semantics(
              label: 'identity key changed warning',
              child: Container(
                width: double.infinity,
                color: EchoTheme.warning.withValues(alpha: 0.15),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: EchoTheme.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Security alert: $_peerUsername's identity key "
                        'has changed. Verify their safety number.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: EchoTheme.warning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      label: 'view safety number',
                      button: true,
                      child: GestureDetector(
                        onTap: _viewSafetyNumber,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: EchoTheme.warning.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: EchoTheme.warning,
                              width: 1,
                            ),
                          ),
                          child: const Text(
                            'Verify',
                            style: TextStyle(
                              fontSize: 11,
                              color: EchoTheme.warning,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Semantics(
                      label: 'trust new identity key',
                      button: true,
                      child: GestureDetector(
                        onTap: _trustNewKey,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: EchoTheme.warning.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: EchoTheme.warning.withValues(alpha: 0.6),
                              width: 1,
                            ),
                          ),
                          child: const Text(
                            'Trust new key',
                            style: TextStyle(
                              fontSize: 11,
                              color: EchoTheme.warning,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Semantics(
                      label: 'dismiss identity key warning',
                      button: true,
                      child: GestureDetector(
                        onTap: _dismiss,
                        child: const Icon(
                          Icons.close,
                          size: 16,
                          color: EchoTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
