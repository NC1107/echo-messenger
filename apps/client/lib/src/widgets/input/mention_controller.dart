import 'package:flutter/foundation.dart';

import '../../models/conversation.dart';
import 'mention_autocomplete.dart' show extractMentionQuery;

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
  /// widget itself, not here.
  List<ConversationMember> filterMembers(
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
