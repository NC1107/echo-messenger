/// Shared markdown regex constants used by both [RichTextContent] (renderer)
/// and [MarkdownTextEditingController] (input preview) so the two can never
/// drift out of sync.
library;

/// Detects URLs in plain text.
final urlRegex = RegExp(r'https?://[^\s]+');

/// Fenced code blocks: ```\n...\n``` (multiline).
final mdCodeBlockRegex = RegExp(r'```\n?([\s\S]*?)```', multiLine: true);

/// Inline code: `...` (single backtick, no nesting).
final mdInlineCodeRegex = RegExp(r'`([^`\n]+)`');

/// Bold: **...**
final mdBoldRegex = RegExp(r'\*\*(.+?)\*\*');

/// Italic: *...* — negative lookahead/lookbehind to skip bold delimiters.
final mdItalicRegex = RegExp(r'(?<!\*)\*([^*]+?)\*(?!\*)');

/// Underline: __...__
final mdUnderlineRegex = RegExp(r'(?<!_)__([^_]+?)__(?!_)');

/// Strikethrough: ~~...~~
final mdStrikethroughRegex = RegExp(r'~~(.+?)~~');

/// Spoiler: ||...||
final mdSpoilerRegex = RegExp(r'\|\|(.+?)\|\|');

/// Masked link: [text](url)
final mdMaskedLinkRegex = RegExp(r'\[([^\]]+)\]\((https?://[^\s)]+)\)');

/// @mention
final mdMentionRegex = RegExp(r'@(\w+)');
