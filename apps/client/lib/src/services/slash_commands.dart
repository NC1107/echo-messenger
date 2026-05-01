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

const _kEveryoneCommands = [('/help or /?', 'Show this help dialog')];

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/// Dispatches a [SlashCommand] for [conversation] using [ref] for provider
/// access and [context] for UI feedback (toasts, dialogs).
///
/// Returns `true` when the command was recognised and handled (caller must
/// NOT send the text as a regular message), `false` when the command is
/// unknown.
Future<bool> dispatchSlashCommand(
  SlashCommand cmd,
  Conversation conversation,
  WidgetRef ref,
  BuildContext context,
) async {
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
