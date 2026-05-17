import 'package:flutter/material.dart';

import '../../services/slash_commands.dart';
import '../../theme/echo_theme.dart';

/// Displays an autocomplete popup for slash commands above the chat input.
///
/// Visible only while the user is still typing the command name — i.e. when
/// [inputText] starts with `/` and contains no space yet.  Hides itself
/// (returns [SizedBox.shrink]) when no commands match or when the user has
/// finished typing the command name.
///
/// When a row is tapped, [onSelect] fires with the command template string
/// (e.g. `/poll "Question?" Option A | Option B`) so the parent can set the
/// input text accordingly.
class SlashCommandAutocomplete extends StatelessWidget {
  final String inputText;
  final void Function(String) onSelect;
  final bool userIsGroupAdmin;

  const SlashCommandAutocomplete({
    super.key,
    required this.inputText,
    required this.onSelect,
    required this.userIsGroupAdmin,
  });

  /// Returns whether the picker should be visible for [inputText].
  ///
  /// Visible iff:
  ///   1. The text starts with `/`.
  ///   2. The text (trimmed) contains no space — the user is still typing the
  ///      command name, not filling in arguments.
  static bool shouldShow(String inputText) {
    if (!inputText.startsWith('/')) return false;
    if (inputText.trim().contains(' ')) return false;
    return true;
  }

  /// The raw query typed after the slash, lower-cased for case-insensitive
  /// matching (e.g. `"po"` for input `"/po"`).
  String get _query => inputText.substring(1).toLowerCase();

  List<SlashCommandHelp> get _matches {
    final commands = availableSlashCommands(includeAdmin: userIsGroupAdmin);
    final q = _query;
    if (q.isEmpty) return commands;
    // Match on the name without the leading slash for a natural feel.
    return commands.where((c) => c.name.substring(1).startsWith(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!shouldShow(inputText)) return const SizedBox.shrink();

    final matches = _matches;
    if (matches.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border.all(color: context.border),
      ),
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.zero,
        itemCount: matches.length,
        itemBuilder: (context, i) {
          final cmd = matches[i];
          return _CommandRow(command: cmd, onTap: () => onSelect(cmd.template));
        },
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final SlashCommandHelp command;
  final VoidCallback onTap;

  const _CommandRow({required this.command, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'slash command ${command.name}',
      hint: command.description,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.terminal_outlined, size: 14, color: context.accent),
              const SizedBox(width: 8),
              Text(
                command.name,
                style: TextStyle(
                  fontSize: 13,
                  color: context.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  command.description,
                  style: TextStyle(fontSize: 11, color: context.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
