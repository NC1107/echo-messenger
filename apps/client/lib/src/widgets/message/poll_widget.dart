import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../models/poll.dart';
import '../../theme/echo_theme.dart';
import '../loading_indicator.dart';

/// Renders a poll inside a message bubble.
///
/// Flow:
/// 1. The `/poll` slash command rewrites to a `[poll:"Q?"|A|B|C]` tag and
///    sends it as the message content.
/// 2. [PollWidget] is shown when `message_item.dart` detects this tag.
/// 3. On first mount the widget calls `GET /api/messages/:id/poll`.
///    - If the server returns 404, the widget creates the poll via
///      `POST /api/messages/:id/poll` (idempotent — only the message sender
///      will trigger this; other members just see the GET succeed).
/// 4. Tapping an option calls `POST /api/messages/:id/poll/vote` then
///    re-fetches vote tallies.
///
/// Real-time updates are deferred to a follow-up: the widget refreshes on
/// every vote it casts; other members see updated counts on their next tap
/// or on history reload.
class PollWidget extends StatefulWidget {
  const PollWidget({
    super.key,
    required this.messageId,
    required this.serverUrl,
    required this.authToken,
    required this.question,
    required this.options,
  });

  final String messageId;
  final String serverUrl;
  final String authToken;

  /// The question text parsed from the message content tag.
  final String question;

  /// The option texts parsed from the message content tag.
  final List<String> options;

  @override
  State<PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<PollWidget> {
  static const String _kPollPrefix = '[poll:';

  Poll? _poll;
  bool _loading = true;
  bool _voting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOrCreate();
  }

  Future<void> _loadOrCreate() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final uri = Uri.parse(
      '${widget.serverUrl}/api/messages/${widget.messageId}/poll',
    );
    final headers = {'Authorization': 'Bearer ${widget.authToken}'};

    try {
      var resp = await http.get(uri, headers: headers);

      // If the poll doesn't exist yet, create it (idempotent: only the first
      // caller wins; subsequent callers get a 409 which we ignore).
      if (resp.statusCode == 404) {
        await http.post(
          uri,
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'question': widget.question,
            'options': widget.options,
          }),
        );
        resp = await http.get(uri, headers: headers);
      }

      if (!mounted) return;
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        setState(() {
          _poll = Poll.fromJson(json);
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _error = 'Could not load poll (${resp.statusCode})';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Network error loading poll';
      });
    }
  }

  Future<void> _vote(int optionIndex) async {
    if (_voting) return;
    setState(() => _voting = true);
    try {
      final resp = await http.post(
        Uri.parse(
          '${widget.serverUrl}/api/messages/${widget.messageId}/poll/vote',
        ),
        headers: {
          'Authorization': 'Bearer ${widget.authToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'option_index': optionIndex}),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        await _loadOrCreate();
      }
    } catch (_) {
      if (!mounted) return;
    }
    if (mounted) setState(() => _voting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _buildShell(
        context,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: InlineLoadingSpinner(size: 20)),
        ),
      );
    }

    if (_error != null) {
      return _buildShell(
        context,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ),
      );
    }

    final poll = _poll;
    if (poll == null) return const SizedBox.shrink();

    final total = poll.totalVotes;
    final hasVoted = poll.myVote != null;

    return _buildShell(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.poll_outlined, size: 14, color: context.textMuted),
                const SizedBox(width: 4),
                Text(
                  'Poll',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.textMuted,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              poll.question,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            ...poll.options.asMap().entries.map(
              (entry) => _buildOption(
                context,
                index: entry.key,
                option: entry.value,
                total: total,
                hasVoted: hasVoted,
                isMyVote: poll.myVote == entry.key,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              total == 1 ? '1 vote' : '$total votes',
              style: TextStyle(fontSize: 11, color: context.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(
    BuildContext context, {
    required int index,
    required PollOption option,
    required int total,
    required bool hasVoted,
    required bool isMyVote,
  }) {
    final pct = total == 0 ? 0.0 : option.count / total;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: _voting ? null : () => _vote(index),
        child: Semantics(
          button: true,
          label: 'Vote for ${option.text}',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isMyVote ? context.accent : context.border,
                width: isMyVote ? 1.5 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                if (hasVoted)
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: pct,
                      child: Container(
                        color: isMyVote
                            ? context.accent.withValues(alpha: 0.18)
                            : context.surface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.text,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isMyVote
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isMyVote
                                ? context.accent
                                : context.textPrimary,
                          ),
                        ),
                      ),
                      if (hasVoted) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${(pct * 100).round()}%',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (isMyVote) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.check_circle,
                          size: 14,
                          color: context.accent,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShell(BuildContext context, {required Widget child}) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.border),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Tag parsing helpers (used by both slash_commands.dart and message_item.dart)
// ---------------------------------------------------------------------------

/// Returns `true` when [content] is a poll message tag of the form
/// `[poll:"question"|Opt1|Opt2|...]`.
bool isPollContent(String content) =>
    content.trimLeft().startsWith(_PollWidgetState._kPollPrefix);

/// Parse a poll content tag.  Returns `null` on malformed input.
///
/// Tag format: `[poll:"Question?"|Option 1|Option 2|Option 3]`
({String question, List<String> options})? parsePollTag(String content) {
  final trimmed = content.trim();
  if (!trimmed.startsWith(_PollWidgetState._kPollPrefix) ||
      !trimmed.endsWith(']')) {
    return null;
  }
  final inner = trimmed.substring(
    _PollWidgetState._kPollPrefix.length,
    trimmed.length - 1,
  );
  if (!inner.startsWith('"')) return null;
  final closeQuote = inner.indexOf('"', 1);
  if (closeQuote < 0) return null;
  final question = inner.substring(1, closeQuote);
  if (question.isEmpty) return null;
  final rest = inner.substring(closeQuote + 1);
  if (!rest.startsWith('|')) return null;
  final options = rest
      .substring(1)
      .split('|')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (options.length < 2) return null;
  return (question: question, options: options);
}
