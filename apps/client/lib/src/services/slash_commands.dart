import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';

// ---------------------------------------------------------------------------
// Command definition
// ---------------------------------------------------------------------------

/// A parsed slash command: the command name (without `/`) and its argument
/// string (everything after the command word, trimmed).
class SlashCommand {
  const SlashCommand({required this.name, required this.args});

  final String name;
  final String args;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Attempts to parse [text] as a slash command.
///
/// Returns a [SlashCommand] when [text] starts with `/` followed by one or
/// more word characters (letters, digits, underscore).  Returns `null` for
/// ordinary chat text.
SlashCommand? parseSlashCommand(String text) {
  final trimmed = text.trim();
  final match = RegExp(r'^/(\w+)\s*(.*)$', dotAll: true).firstMatch(trimmed);
  if (match == null) return null;
  return SlashCommand(
    name: match.group(1)!.toLowerCase(),
    args: match.group(2)!.trim(),
  );
}

// ---------------------------------------------------------------------------
// Help content
// ---------------------------------------------------------------------------

const _kAdminCommands = [
  ('/name <new name>', 'Rename the group'),
  ('/description <text>', 'Set the group description'),
  ('/kick @username', 'Remove a member from the group'),
];

const _kFunCommands = [
  ('/shrug [text]', 'Send text with shrug emoticon'),
  ('/tableflip [text]', 'Send text with table flip emoticon'),
  ('/unflip [text]', 'Send text with unflip emoticon'),
  ('/me <action>', 'Send an action line (italicized)'),
  ('/lenny [text]', 'Send text with Lenny face'),
  ('/flip [text]', 'Send text upside down'),
];

const _kPollCommands = [
  ('/poll "Question?" Opt1 | Opt2 | Opt3', 'Create a poll'),
];

const _kEveryoneCommands = [('/help or /?', 'Show this help dialog')];

// ---------------------------------------------------------------------------
// Fun command rewriting
// ---------------------------------------------------------------------------

/// Maps a character to its upside-down equivalent for /flip command.
const Map<String, String> _flipMap = {
  'a': 'ɐ',
  'b': 'q',
  'c': 'ɔ',
  'd': 'p',
  'e': 'ǝ',
  'f': 'ɟ',
  'g': 'ƃ',
  'h': 'ɥ',
  'i': 'ᴉ',
  'j': 'ɾ',
  'k': 'ʞ',
  'l': 'l',
  'm': 'ɯ',
  'n': 'u',
  'o': 'o',
  'p': 'd',
  'q': 'b',
  'r': 'ɹ',
  's': 's',
  't': 'ʇ',
  'u': 'n',
  'v': 'ʌ',
  'w': 'ʍ',
  'x': 'x',
  'y': 'ʎ',
  'z': 'z',
  'A': '∀',
  'B': 'ᙠ',
  'C': 'Ɔ',
  'D': 'ᗡ',
  'E': 'Ǝ',
  'F': 'Ⅎ',
  'G': '⅁',
  'H': 'H',
  'I': 'I',
  'J': 'ſ',
  'K': 'ʞ',
  'L': '˥',
  'M': 'W',
  'N': 'N',
  'O': 'O',
  'P': 'Ԁ',
  'Q': 'Ὸ',
  'R': 'ᴚ',
  'S': 'S',
  'T': '⊥',
  'U': '∩',
  'V': 'Λ',
  'W': 'M',
  'X': 'X',
  'Y': '⅄',
  'Z': 'Z',
  '0': '0',
  '1': 'Ɩ',
  '2': 'ᄅ',
  '3': 'Ɛ',
  '4': 'ㄣ',
  '5': 'ϛ',
  '6': '9',
  '7': 'ㄥ',
  '8': '8',
  '9': '6',
  '.': '˙',
  ',': "'",
  "'": ',',
  '"': '„',
  '!': '¡',
  '?': '¿',
  '(': ')',
  ')': '(',
  '[': ']',
  ']': '[',
  '{': '}',
  '}': '{',
  '<': '>',
  '>': '<',
  '&': '⅋',
};

/// Rewrites a fun slash command to its message text equivalent.
///
/// Returns the rewritten message string for fun commands, or null for
/// admin commands (which are handled by the dispatcher separately).
String? rewriteSlashCommand(
  SlashCommand cmd, {
  required String senderUsername,
}) {
  switch (cmd.name) {
    case 'shrug':
      final text = cmd.args.isEmpty ? '' : '${cmd.args} ';
      return '$text¯\\_(ツ)_/¯';

    case 'tableflip':
      final text = cmd.args.isEmpty ? '' : '${cmd.args} ';
      return '$text(╯°□°)╯︵ ┻━┻';

    case 'unflip':
      final text = cmd.args.isEmpty ? '' : '${cmd.args} ';
      return '$text┬─┬ノ( º_ºノ)';

    case 'me':
      if (cmd.args.isEmpty) {
        return null; // No-op if no action provided
      }
      return '_$senderUsername ${cmd.args}_';

    case 'lenny':
      final text = cmd.args.isEmpty ? '' : '${cmd.args} ';
      return '$text( ͡° ͜ʖ ͡°)';

    case 'flip':
      if (cmd.args.isEmpty) {
        return null; // No rewrite if empty
      }
      // Flip the text and reverse the order
      final chars = cmd.args.split('');
      final flipped = chars.map((c) => _flipMap[c] ?? c).toList();
      flipped.reversed;
      return flipped.reversed.join('');

    default:
      return null; // Not a fun command
  }
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/// Dispatches a [SlashCommand] for [conversation] using [ref] for provider
/// access and [context] for UI feedback (toasts, dialogs).
///
/// Returns `true` when the command was recognised and handled (caller must
/// NOT send the text as a regular message), `false` when the command is
/// unknown.
///
/// When this returns true and the caller receives a rewritten message text via
/// [onRewrite], the caller should send that text as a regular message.
Future<bool> dispatchSlashCommand(
  SlashCommand cmd,
  Conversation conversation,
  WidgetRef ref,
  BuildContext context, {
  void Function(String)? onRewrite,
}) async {
  // Check if this is a fun command that rewrites to a message
  final senderUsername = ref.read(authProvider).username ?? 'User';
  final rewrittenText = rewriteSlashCommand(
    cmd,
    senderUsername: senderUsername,
  );
  if (rewrittenText != null) {
    // This is a fun command; notify caller to send the rewritten text
    onRewrite?.call(rewrittenText);
    return true;
  }
  switch (cmd.name) {
    case 'help':
    case '?':
      _showHelp(context, conversation, ref);
      return true;

    case 'name':
      if (!conversation.isGroup) {
        _toast(context, '/name is only available in groups', ToastType.warning);
        return true;
      }
      if (!_callerIsAdmin(conversation, ref)) {
        _toast(context, 'Only admins can rename the group', ToastType.warning);
        return true;
      }
      if (cmd.args.isEmpty) {
        _toast(context, 'Usage: /name <new name>', ToastType.info);
        return true;
      }
      await _renameGroup(conversation, cmd.args, ref, context);
      return true;

    case 'description':
      if (!conversation.isGroup) {
        _toast(
          context,
          '/description is only available in groups',
          ToastType.warning,
        );
        return true;
      }
      if (!_callerIsAdmin(conversation, ref)) {
        _toast(
          context,
          'Only admins can change the description',
          ToastType.warning,
        );
        return true;
      }
      await _setDescription(conversation, cmd.args, ref, context);
      return true;

    case 'kick':
      if (!conversation.isGroup) {
        _toast(context, '/kick is only available in groups', ToastType.warning);
        return true;
      }
      if (!_callerIsAdmin(conversation, ref)) {
        _toast(context, 'Only admins can kick members', ToastType.warning);
        return true;
      }
      if (cmd.args.isEmpty) {
        _toast(context, 'Usage: /kick @username', ToastType.info);
        return true;
      }
      await _kickMember(conversation, cmd.args, ref, context);
      return true;

    case 'poll':
      final pollTag = _buildPollTag(cmd.args);
      if (pollTag == null) {
        _toast(
          context,
          'Usage: /poll "Question?" Option 1 | Option 2 | Option 3',
          ToastType.info,
        );
        return true;
      }
      onRewrite?.call(pollTag);
      return true;

    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// Helper: role check
// ---------------------------------------------------------------------------

bool _callerIsAdmin(Conversation conversation, WidgetRef ref) {
  final myUserId = ref.read(authProvider).userId ?? '';
  final me = conversation.members
      .where((m) => m.userId == myUserId)
      .firstOrNull;
  final role = me?.role?.toLowerCase();
  return role == 'admin' || role == 'owner';
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

Future<void> _renameGroup(
  Conversation conversation,
  String newName,
  WidgetRef ref,
  BuildContext context,
) async {
  final serverUrl = ref.read(serverUrlProvider);
  try {
    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.put(
            Uri.parse('$serverUrl/api/groups/${conversation.id}'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'title': newName}),
          ),
        );
    if (!context.mounted) return;
    if (response.statusCode == 200) {
      await ref.read(conversationsProvider.notifier).loadConversations();
      if (!context.mounted) return;
      _toast(context, 'Group renamed to "$newName"', ToastType.success);
    } else {
      _toast(
        context,
        'Failed to rename group (${response.statusCode})',
        ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, 'Network error renaming group', ToastType.error);
  }
}

Future<void> _setDescription(
  Conversation conversation,
  String description,
  WidgetRef ref,
  BuildContext context,
) async {
  final serverUrl = ref.read(serverUrlProvider);
  try {
    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.put(
            Uri.parse('$serverUrl/api/groups/${conversation.id}'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'description': description}),
          ),
        );
    if (!context.mounted) return;
    if (response.statusCode == 200) {
      await ref.read(conversationsProvider.notifier).loadConversations();
      if (!context.mounted) return;
      _toast(context, 'Group description updated', ToastType.success);
    } else {
      _toast(
        context,
        'Failed to update description (${response.statusCode})',
        ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, 'Network error updating description', ToastType.error);
  }
}

Future<void> _kickMember(
  Conversation conversation,
  String rawArg,
  WidgetRef ref,
  BuildContext context,
) async {
  // Strip leading '@' if present.
  final username = rawArg.startsWith('@') ? rawArg.substring(1) : rawArg;

  final member = conversation.members
      .where((m) => m.username.toLowerCase() == username.toLowerCase())
      .firstOrNull;

  if (member == null) {
    _toast(context, '@$username is not in this group', ToastType.warning);
    return;
  }

  final myUserId = ref.read(authProvider).userId ?? '';
  if (member.userId == myUserId) {
    _toast(context, 'You cannot kick yourself', ToastType.warning);
    return;
  }

  final serverUrl = ref.read(serverUrlProvider);
  try {
    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.delete(
            Uri.parse(
              '$serverUrl/api/groups/${conversation.id}/members/${member.userId}',
            ),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );
    if (!context.mounted) return;
    if (response.statusCode == 200) {
      await ref.read(conversationsProvider.notifier).loadConversations();
      if (!context.mounted) return;
      _toast(
        context,
        '${member.username} removed from group',
        ToastType.success,
      );
    } else {
      _toast(
        context,
        'Failed to remove ${member.username} (${response.statusCode})',
        ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, 'Network error removing member', ToastType.error);
  }
}

// ---------------------------------------------------------------------------
// Poll tag builder
// ---------------------------------------------------------------------------

/// Parses `/poll` args of the form `"Question?" Option 1 | Option 2 | ...`
/// and returns the wire tag `[poll:"Question?"|Option 1|Option 2|...]`.
///
/// Returns `null` when the args are malformed (missing question or fewer than
/// 2 options) so the dispatcher can show a usage hint.
String? _buildPollTag(String args) {
  if (args.isEmpty) return null;

  String question;
  String rest;

  // Accept quoted question: "Question?" Opt1 | Opt2
  if (args.startsWith('"')) {
    final closeQuote = args.indexOf('"', 1);
    if (closeQuote < 0) return null;
    question = args.substring(1, closeQuote).trim();
    rest = args.substring(closeQuote + 1).trim();
    if (rest.startsWith('|')) rest = rest.substring(1);
  } else {
    // Unquoted: first pipe-delimited segment is the question
    final parts = args.split('|');
    if (parts.length < 3) return null;
    question = parts.first.trim();
    rest = parts.sublist(1).join('|');
  }

  if (question.isEmpty) return null;

  final options = rest
      .split('|')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  if (options.length < 2) return null;

  // Encode as [poll:"Question?"|Opt1|Opt2|...]
  final optPart = options.join('|');
  return '[poll:"$question"|$optPart]';
}

// ---------------------------------------------------------------------------
// Help dialog
// ---------------------------------------------------------------------------

void _showHelp(BuildContext context, Conversation conversation, WidgetRef ref) {
  final isAdmin = conversation.isGroup && _callerIsAdmin(conversation, ref);

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Slash Commands'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isAdmin) ...[
              const Text(
                'Admin commands',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              ..._kAdminCommands.map((e) => _CommandRow(cmd: e.$1, desc: e.$2)),
              const SizedBox(height: 12),
            ],
            const Text(
              'Fun',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ..._kFunCommands.map((e) => _CommandRow(cmd: e.$1, desc: e.$2)),
            const SizedBox(height: 12),
            const Text(
              'Polls',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ..._kPollCommands.map((e) => _CommandRow(cmd: e.$1, desc: e.$2)),
            const SizedBox(height: 12),
            const Text(
              'Everyone',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ..._kEveryoneCommands.map(
              (e) => _CommandRow(cmd: e.$1, desc: e.$2),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.cmd, required this.desc});

  final String cmd;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              cmd,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(desc, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

void _toast(BuildContext context, String msg, ToastType type) {
  if (context.mounted) {
    ToastService.show(context, msg, type: type);
  }
}
