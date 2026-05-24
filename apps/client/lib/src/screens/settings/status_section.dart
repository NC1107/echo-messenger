import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../widgets/settings_panel_scaffold.dart';

/// Maximum characters accepted by `PUT /api/users/me/status-text`.
/// The server caps at 64; we enforce 80 in the field but show a counter so
/// users know when they are near the server limit.
const _kMaxStatusLength = 80;

/// Settings section that lets the authenticated user set or clear a short
/// custom status text.  The text is persisted via
/// `PUT /api/users/me/status-text` and surfaced next to the user's name in
/// conversations.
class StatusSection extends ConsumerStatefulWidget {
  const StatusSection({super.key});

  @override
  ConsumerState<StatusSection> createState() => _StatusSectionState();
}

class _StatusSectionState extends ConsumerState<StatusSection> {
  late final TextEditingController _controller;
  bool _isDirty = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(authProvider).statusText ?? '';
    _controller = TextEditingController(text: initial);
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final current = ref.read(authProvider).statusText ?? '';
    final changed = _controller.text.trim() != current.trim();
    if (changed != _isDirty) {
      setState(() => _isDirty = changed);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final text = _controller.text.trim();
    setState(() => _isSaving = true);
    try {
      await ref.read(authProvider.notifier).setStatusText(text);
      if (!mounted) return;
      setState(() {
        _isDirty = false;
        _isSaving = false;
      });
      ToastService.show(context, 'Status saved.', type: ToastType.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ToastService.show(
        context,
        'Failed to save status. Please try again.',
        type: ToastType.error,
      );
    }
  }

  Future<void> _clear() async {
    if (_isSaving) return;
    setState(() {
      _controller.text = '';
      _isSaving = true;
    });
    try {
      await ref.read(authProvider.notifier).setStatusText(null);
      if (!mounted) return;
      setState(() {
        _isDirty = false;
        _isSaving = false;
      });
      ToastService.show(context, 'Status cleared.', type: ToastType.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ToastService.show(
        context,
        'Failed to clear status. Please try again.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final charCount = _controller.text.length;
    final overLimit = charCount > _kMaxStatusLength;

    return SettingsPanelScaffold(
      children: [
        // Section header
        Text(
          'Status',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your status appears next to your name in conversations.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),

        // Text field
        TextField(
          controller: _controller,
          maxLength: null, // manual counter below
          maxLines: 1,
          inputFormatters: [
            // Hard-cap at 2× the limit so the user can see the counter
            // turn red before being forcibly cut off.
            LengthLimitingTextInputFormatter(_kMaxStatusLength * 2),
          ],
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: "What's on your mind?",
            hintStyle: TextStyle(color: context.textMuted, fontSize: 14),
            filled: true,
            fillColor: context.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.accent, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: EchoTheme.danger),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: EchoTheme.danger, width: 1.5),
            ),
            errorText: overLimit
                ? 'Status must be $_kMaxStatusLength characters or fewer'
                : null,
          ),
        ),

        // Character counter
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$charCount / $_kMaxStatusLength',
            style: TextStyle(
              color: overLimit ? EchoTheme.danger : context.textMuted,
              fontSize: 11,
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: (_isDirty && !overLimit && !_isSaving)
                    ? _save
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: context.accent,
                  disabledBackgroundColor: context.accent.withValues(
                    alpha: 0.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: _isSaving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.textPrimary,
                        ),
                      )
                    : const Text('Save'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : _clear,
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textSecondary,
                  side: BorderSide(color: context.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Clear'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
