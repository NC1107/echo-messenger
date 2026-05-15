import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';

/// Top-level entry: open the "Send feedback" dialog. Resolves to `true` when
/// the report was POSTed successfully, `false` on cancel / failure.
///
/// The dialog is intentionally lightweight -- title + body + public-ok
/// checkbox -- matching the matching server contract in
/// `apps/server/src/routes/feedback.rs`.  Server-side rate limit kicks in
/// at 5 reports per 24h; the dialog surfaces a toast on 429 rather than
/// blocking submission client-side.
Future<bool?> showFeedbackDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const _FeedbackDialog(),
  );
}

class _FeedbackDialog extends ConsumerStatefulWidget {
  const _FeedbackDialog();

  @override
  ConsumerState<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends ConsumerState<_FeedbackDialog> {
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  // Mirrors the server caps in `routes::feedback`.  We enforce client-side
  // so the user gets immediate feedback instead of a 400 round-trip.
  static const int _maxTitle = 100;
  static const int _maxBody = 4000;

  bool _publicOk = false;
  bool _sending = false;
  String? _errorText;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  bool get _canSend =>
      !_sending &&
      _titleController.text.trim().isNotEmpty &&
      _bodyController.text.trim().isNotEmpty;

  Future<void> _send() async {
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();
    if (title.isEmpty || body.isEmpty) return;

    setState(() {
      _sending = true;
      _errorText = null;
    });

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final resp = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/feedback'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'title': title,
                'body': body,
                'public_ok': _publicOk,
              }),
            ),
          );

      if (!mounted) return;

      if (resp.statusCode == 201) {
        Navigator.of(context).pop(true);
        ToastService.show(
          context,
          'Thanks — your report was sent.',
          type: ToastType.success,
        );
        return;
      }

      if (resp.statusCode == 429) {
        setState(() {
          _errorText =
              "You've sent several reports recently. Please try again later.";
        });
        return;
      }

      // Best-effort decode of the server error envelope.
      String message = 'Could not send. Please try again.';
      try {
        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        final msg = decoded['error'] ?? decoded['message'];
        if (msg is String && msg.isNotEmpty) {
          message = msg;
        }
      } catch (_) {}
      setState(() => _errorText = message);
    } catch (_) {
      if (mounted) {
        setState(() => _errorText = 'Network error. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.border),
      ),
      title: Row(
        children: [
          Icon(Icons.feedback_outlined, size: 20, color: context.textSecondary),
          const SizedBox(width: 8),
          Text(
            'Send feedback',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Found a bug or have a suggestion? Tell us about it. Your '
              'report goes straight to the maintainer.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              maxLength: _maxTitle,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Short summary',
                counterText: '',
              ),
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bodyController,
              maxLength: _maxBody,
              maxLines: 6,
              minLines: 4,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Details',
                hintText: 'Steps to reproduce, what you expected, etc.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('feedback-public-ok-checkbox'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _publicOk,
              onChanged: (v) => setState(() => _publicOk = v ?? false),
              title: Text(
                'OK to share this report publicly on GitHub',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
              subtitle: Text(
                'If unchecked, only the maintainer sees this.',
                style: TextStyle(color: context.textMuted, fontSize: 11.5),
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorText!,
                style: const TextStyle(color: EchoTheme.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('feedback-send-button'),
          onPressed: _canSend ? _send : null,
          icon: _sending
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.onAccent,
                  ),
                )
              : const Icon(Icons.send, size: 16),
          label: Text(_sending ? 'Sending...' : 'Send'),
        ),
      ],
    );
  }
}
