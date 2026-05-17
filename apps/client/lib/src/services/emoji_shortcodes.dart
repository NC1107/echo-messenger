/// Emoji shortcode mapping for Discord/Slack-style abbreviations.
/// Typing `:smile:` will be replaced with the actual emoji at send-time.
///
/// Contains the most common 50 emoji with their standard shortcodes.
/// Follows Discord/Slack convention: alphanumeric + underscore, lowercase.
final emojiShortcodes = <String, String>{
  // Smileys & Emotion
  'smile': '😄',
  'laughing': '😆',
  'joy': '😂',
  'smiley': '😃',
  'sweat_smile': '😅',
  'grin': '😁',
  'wink': '😉',
  'blush': '😊',
  'heart_eyes': '😍',
  'kissing_heart': '😘',
  'relaxed': '☺️',
  'grinning': '😀',
  'stuck_out_tongue': '😛',
  'stuck_out_tongue_winking_eye': '😜',
  'sleeping': '😴',
  'worried': '😟',
  'frowning': '☹️',
  'anguished': '😧',
  'angry': '😠',
  'rage': '😡',
  'cry': '😢',
  'persevere': '😣',
  'cold_sweat': '😰',
  'kissing': '😗',
  'sunglasses': '😎',
  'dizzy_face': '😵',

  // Hand Gestures
  'thumbsup': '👍',
  'thumbsdown': '👎',
  '+1': '👍',
  '-1': '👎',
  'ok_hand': '👌',
  'raised_hand': '✋',
  'v': '✌️',
  'pray': '🙏',
  'clap': '👏',
  'fist': '✊',
  'point_right': '👉',

  // Objects & Symbols
  'heart': '❤️',
  'yellow_heart': '💛',
  'blue_heart': '💙',
  'purple_heart': '💜',
  'green_heart': '💚',
  'star': '⭐',
  'sparkles': '✨',
  'boom': '💥',
  'fire': '🔥',
  'tada': '🎉',
  'rocket': '🚀',
  'eyes': '👀',
  'think': '🤔',
  'wave': '👋',
};

/// Replaces emoji shortcodes (e.g., `:smile:`) with actual emoji glyphs.
/// Only matches shortcodes in the registry above.
/// Used at message send-time to expand user input.
String expandEmojiShortcodes(String text) {
  var result = text;
  emojiShortcodes.forEach((shortcode, emoji) {
    result = result.replaceAll(':$shortcode:', emoji);
  });
  return result;
}
