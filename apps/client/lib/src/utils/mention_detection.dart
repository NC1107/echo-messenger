/// Word-boundary scanner for `@`-mentions in plaintext message content.
///
/// Used by the WS handler to mark a conversation as "mentioned" when an
/// incoming message contains `@<myUsername>`, `@everyone`, or `@here`.
/// Mirrors the server-side `mentions_broadcast` helper
/// (`apps/server/src/ws/message_service.rs`) but stays decoupled — the
/// client may grow client-only mention features later (e.g., custom
/// keyword highlights, mute-mentions-from-X).
///
/// Boundary rule: `@` is preceded by start-of-string or whitespace /
/// non-word character, and the keyword is followed by end-of-string or
/// non-word character.  Word characters are `[A-Za-z0-9_]`.  This
/// matches what the autocomplete picker treats as a mention trigger
/// and avoids false positives like `me@host` or `@hereabouts`.
library;

/// Returns true when [content] contains a mention of [myUsername]
/// (case-insensitive) or one of the broadcast keywords (`@everyone`,
/// `@here`).
///
/// [myUsername] may be `null` or empty when the user is not yet
/// authenticated — in that case only broadcast keywords are matched.
bool containsMention(String content, String? myUsername) {
  if (content.isEmpty) return false;
  if (_containsKeyword(content, 'everyone')) return true;
  if (_containsKeyword(content, 'here')) return true;
  if (myUsername == null || myUsername.isEmpty) return false;
  return _containsKeyword(content, myUsername);
}

/// Returns true when `@<keyword>` appears in [content] as a standalone
/// token.  Case-insensitive.  Exposed for tests; prefer [containsMention]
/// for application code.
bool containsKeywordMention(String content, String keyword) =>
    _containsKeyword(content, keyword);

bool _containsKeyword(String content, String keyword) {
  if (keyword.isEmpty) return false;
  final target = '@${keyword.toLowerCase()}';
  final lower = content.toLowerCase();
  var start = 0;
  while (true) {
    final rel = lower.indexOf(target, start);
    if (rel < 0) return false;
    final after = rel + target.length;
    final leftOk = rel == 0 || !_isWordChar(lower.codeUnitAt(rel - 1));
    final rightOk =
        after == lower.length || !_isWordChar(lower.codeUnitAt(after));
    if (leftOk && rightOk) return true;
    start = rel + target.length;
  }
}

bool _isWordChar(int codeUnit) {
  // ASCII alphanumeric or underscore.  Non-ASCII chars (e.g., accented
  // letters) count as non-word so a username like "café" still matches
  // when followed by punctuation.  This is consistent with the server
  // behavior — strict-ASCII boundary checks for the mention path.
  return (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
      (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
      (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
      codeUnit == 0x5F; // _
}
