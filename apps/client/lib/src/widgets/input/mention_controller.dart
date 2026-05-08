import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingValue, TextSelection;

import '../../models/conversation.dart';

/// Attempts to extract a partial mention query from [text] at the given
/// [cursorPosition]. Returns the lowercased query string when an active `@`
/// trigger is found, or `null` when no mention autocomplete should be shown.
///
/// The character preceding `@` must be whitespace (space, tab, newline) or
/// the start of the string — this avoids triggering on email addresses
/// like `me@host` while still working when a user pastes a multi-line
/// draft.  The server's broadcast scanner uses a stricter "any non-word
/// character" rule, but the client picker stays conservative on purpose.
String? extractMentionQuery(String text, int cursorPosition) {
  if (cursorPosition < 0 || cursorPosition > text.length) return null;

  final beforeCursor = text.substring(0, cursorPosition);
  final atIndex = beforeCursor.lastIndexOf('@');
  if (atIndex < 0) return null;

  if (atIndex > 0) {
    final prev = beforeCursor[atIndex - 1];
    final isWhitespace = RegExp(r'\s').hasMatch(prev);
    if (!isWhitespace) return null;
  }

  final partial = beforeCursor.substring(atIndex + 1);
  if (RegExp(r'\s').hasMatch(partial)) return null;

  return partial.toLowerCase();
}

/// Inserts a completed @mention into [text] at the cursor position, replacing
/// the partial query. Returns the new [TextEditingValue] with updated cursor.
TextEditingValue insertMention({
  required String text,
  required int cursorPosition,
  required String username,
}) {
  if (cursorPosition < 0) return TextEditingValue(text: text);

  final beforeCursor = text.substring(0, cursorPosition);
  final atIndex = beforeCursor.lastIndexOf('@');
  if (atIndex < 0) return TextEditingValue(text: text);

  final afterCursor = text.substring(cursorPosition);
  final replacement = '@$username ';
  final newText = text.substring(0, atIndex) + replacement + afterCursor;
  final newCursorPos = atIndex + replacement.length;

  return TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: newCursorPos),
  );
}

/// State holder for the @-mention picker that floats above the chat composer.
///
/// Owns picker visibility and the partial `@`-query, plus the keystroke
/// detection that toggles the picker. Lifted out of `ChatInputBarState`
/// so it can be unit-tested without rendering the full composer (#513).
class MentionComposerController extends ChangeNotifier {
  bool _showPicker = false;
  String _query = '';

  bool get showPicker => _showPicker;
  String get query => _query;

  /// Re-evaluate visibility from the latest [text] / [cursorPosition].
  /// Disabled in 1:1 DMs (the picker is group-only), so [isGroup] forces
  /// the picker closed regardless of input.
  void detect({
    required String text,
    required int cursorPosition,
    required bool isGroup,
  }) {
    if (!isGroup) {
      _set(showPicker: false, query: '');
      return;
    }

    final next = extractMentionQuery(text, cursorPosition);
    if (next == null) {
      _set(showPicker: false, query: '');
    } else {
      _set(showPicker: true, query: next);
    }
  }

  /// Close the picker (Escape, conversation switch, after a tap).
  void dismiss() => _set(showPicker: false, query: '');

  /// Filter members eligible for mention suggestions. Excludes the local
  /// user; broadcast rows (@everyone / @here) are added by the autocomplete
  /// widget itself, not here.  Pure transformation — no controller state
  /// is read or written.
  static List<ConversationMember> filterMembers(
    List<ConversationMember> members,
    String myUserId,
  ) {
    return members.where((m) => m.userId != myUserId).toList();
  }

  void _set({required bool showPicker, required String query}) {
    if (_showPicker == showPicker && _query == query) return;
    _showPicker = showPicker;
    _query = query;
    notifyListeners();
  }
}
