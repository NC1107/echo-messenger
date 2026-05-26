import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/debug_log_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../version.dart';

/// Top-level entry: open the "Send feedback" dialog. Resolves to `true` when
/// the report was POSTed successfully, `false` on cancel / failure.
///
/// The dialog is intentionally lightweight -- a single body field plus a
/// "share debug logs" toggle. Title is derived from the body's first line and
/// `public_ok` is always false; the simplification matches #1159. The server
/// contract lives in `apps/server/src/routes/feedback.rs`. Server-side rate
/// limit kicks in at 5 reports per 24h; the dialog surfaces a toast on 429
/// rather than blocking submission client-side.
Future<bool?> showFeedbackDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const _FeedbackDialog(),
  );
}

/// Maximum body characters mirrored from server's [`MAX_BODY_CHARS`].
const int _kMaxBody = 4000;

/// How many of the most recent log lines we attach when the user opts in.
const int _kLogsTailEntries = 200;

/// Title character cap mirrored from server's [`MAX_TITLE_CHARS`]; we derive
/// the title from the body's first line and truncate to fit.
const int _kMaxTitle = 80;

/// Single-character ellipsis used when truncating a derived title.
const String _kEllipsis = '…';

/// Resolve the platform string sent alongside feedback reports.
///
/// Web builds always report `'web'`; native platforms use the
/// `dart:io` operating system name (`linux`, `windows`, `macos`,
/// `android`, `ios`).
String _resolvePlatformName() {
  if (kIsWeb) return 'web';
  return Platform.operatingSystem;
}

/// Derive the report title from the first non-empty line of [body].
///
/// Truncates to [_kMaxTitle] characters with a trailing ellipsis if the line
/// is longer. Returns an empty string when [body] has no non-empty line —
/// the caller's send button is disabled in that case so the empty title never
/// reaches the wire.
String deriveFeedbackTitle(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.length <= _kMaxTitle) return line;
    // Reserve one character for the ellipsis so the cap is honored exactly.
    return '${line.substring(0, _kMaxTitle - 1)}$_kEllipsis';
  }
  return '';
}

/// Build the JSON payload posted to `/api/feedback`.
///
/// Extracted so the widget test can exercise the field-shaping logic without
/// pumping the full dialog (which depends on overlay + auth + http mocks).
/// `logs` is only included when [shareLogs] is true; an empty/null tail also
/// omits the field so the server isn't forced to validate an empty string.
@visibleForTesting
Map<String, dynamic> buildFeedbackPayload({
  required String body,
  required bool shareLogs,
  required String appVersion,
  required String platformName,
  DebugLogService? logService,
}) {
  final trimmedBody = body.trim();
  final title = deriveFeedbackTitle(trimmedBody);
  final payload = <String, dynamic>{
    'title': title,
    'body': trimmedBody,
    'public_ok': false,
    'app_version': appVersion,
    'platform': platformName,
  };
  if (shareLogs) {
    final logs = (logService ?? DebugLogService.instance).tail(
      _kLogsTailEntries,
    );
    if (logs.isNotEmpty) {
      payload['logs'] = logs;
    }
  }
  return payload;
}

class _FeedbackDialog extends ConsumerStatefulWidget {
  const _FeedbackDialog();

  @override
  ConsumerState<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends ConsumerState<_FeedbackDialog> {
  final _bodyController = TextEditingController();

  bool _shareLogs = true;
  bool _sending = false;
  String? _errorText;

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  bool get _canSend => !_sending && _bodyController.text.trim().isNotEmpty;

  Future<void> _send() async {
    final body = _bodyController.text.trim();
    if (body.isEmpty) return;

    // Capture root overlay before await — dialog's own context is disposed by the time the toast resolves (#928).
    final rootOverlay = Overlay.of(context, rootOverlay: true);

    setState(() {
      _sending = true;
      _errorText = null;
    });

    final serverUrl = ref.read(serverUrlProvider);
    final payload = buildFeedbackPayload(
      body: body,
      shareLogs: _shareLogs,
      appVersion: appVersion,
      platformName: _resolvePlatformName(),
    );
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
              body: jsonEncode(payload),
            ),
          );

      if (!mounted) return;

      if (resp.statusCode == 201) {
        Navigator.of(context).pop(true);
        ToastService.show(
          context,
          'Thanks — your report was sent.',
          type: ToastType.success,
          overlay: rootOverlay,
        );
        return;
      }

      if (resp.statusCode == 429) {
        setState(() {
          _errorText =
              "You've sent several reports recently. Please try again later.";
        });
        ToastService.show(
          context,
          "You've sent several reports recently. Please try again later.",
          type: ToastType.warning,
          overlay: rootOverlay,
        );
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
      ToastService.show(
        context,
        message,
        type: ToastType.error,
        overlay: rootOverlay,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _errorText = 'Network error. Please try again.');
        ToastService.show(
          context,
          'Network error. Please try again.',
          type: ToastType.error,
          overlay: rootOverlay,
        );
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
              controller: _bodyController,
              maxLength: _kMaxBody,
              maxLines: 10,
              minLines: 4,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Describe the bug',
                hintText: 'Steps to reproduce, what you expected, etc.',
              ),
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('feedback-share-logs-switch'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _shareLogs,
              onChanged: _sending
                  ? null
                  : (v) => setState(() => _shareLogs = v),
              title: Text(
                'Share debug logs',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
              subtitle: Text(
                'Attaches the last $_kLogsTailEntries log entries so the '
                'maintainer can diagnose crashes.',
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
